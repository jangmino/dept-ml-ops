#!/usr/bin/env bash
set -euo pipefail

# =========================
# teamctl-xfs.sh (FINAL + Remote NFS quota + NFS bind mount)
# - Local workspace: XFS project quota on GPU server (/data)
# - Optional NFS workspace: created+quota via remote nfsctl on storage server, mounted on host, bind-mounted into container
#
# Local (GPU server):
#   - DATA_ROOT=/data must be XFS mounted with prjquota
#   - /workspace and /home/<team> share the same local quota-controlled dir
#
# NFS:
#   - Storage server has /opt/nfs/nfsctl.sh (project quota on /nfs)
#   - GPU server already mounts storage NFS at: NFS_MOUNT=/mnt/nfs/teams
#   - Team dir on host: /mnt/nfs/teams/<team>
#   - Inside container: /nfs/team (read-write)
#
# IMPORTANT:
# - Local quota (/data) and NFS quota are independent and can differ.
# =========================

BASE_DIR="/opt/mlops"
COMPOSE_FILE="${BASE_DIR}/compose.yaml"
GPU_MODE_FILE="${BASE_DIR}/.gpu_mode"

# ---- Local storage (XFS prjquota) ----
DATA_ROOT="/data"               # must be XFS mounted with prjquota
TEAMS_DIR="${DATA_ROOT}/teams"
SSH_DIR="${DATA_ROOT}/ssh"
SSH_BACKUP_DIR="${DATA_ROOT}/ssh_backups"

# ---- NFS bind mount (host already mounted) ----
NFS_MOUNT_DEFAULT="/mnt/nfs/teams"      # host mount point (already mounted)
NFS_CONTAINER_PATH_DEFAULT="/nfs/team"  # inside container

# ---- Remote NFS quota controller (storage server) ----
NFS_HOST_DEFAULT="210.125.91.94"
NFS_SSH_USER_DEFAULT="nfsadmin"
NFS_SSH_PORT_DEFAULT="22"
NFS_SSH_KEY_DEFAULT="/opt/mlops/keys/nfsctl_ed25519"
NFSCTL_REMOTE_PATH_DEFAULT="/opt/nfs/nfsctl.sh"

# ---- Bastion (SSH gateway: jump user) ----
JUMP_USER="jump"
JUMP_HOME="/home/jump"
JUMP_SSH_DIR="${JUMP_HOME}/.ssh"
JUMP_AUTHKEYS="${JUMP_SSH_DIR}/authorized_keys"
JUMP_SSHD_CONF="/etc/ssh/sshd_config.d/jump.conf"

PROJECTS_FILE="/etc/projects"
PROJID_FILE="/etc/projid"

DEFAULT_UID_BASE=12000
DEFAULT_PORT_BASE=22020         # team01 -> 22021
DEFAULT_TEAM_HARD="300G"
DEFAULT_TEAM_SOFT="290G"

DEFAULT_IMAGE="mlops:latest"
DEFAULT_SHM_SIZE="16g"
DEFAULT_IPC="host"
DEFAULT_RESTART="unless-stopped"

# security toggles (keep simple; you can harden later)
DEFAULT_ALLOW_SUDO="true"
DEFAULT_SUDO_POLICY="full_no_shell"

log(){ echo "$@"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

need_root(){
  [[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)."
}

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

ensure_dirs(){
  mkdir -p "${BASE_DIR}" "${TEAMS_DIR}" "${SSH_DIR}" "${SSH_BACKUP_DIR}"
}

need_compose(){
  [[ -f "${COMPOSE_FILE}" ]] || {
    cat > "${COMPOSE_FILE}" <<'YAML'
services:
YAML
  }
}

# -------------------------
# Helpers: team parsing
# -------------------------
team_num_from_name(){
  # Extract trailing digits; team01 -> 1
  local team="$1"
  local digits
  digits="$(echo "${team}" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)$/\1/p')"
  if [[ -n "${digits}" ]]; then
    echo "$((10#${digits}))"
  else
    echo ""
  fi
}

default_ids_for_team(){
  local team="$1"
  local n
  n="$(team_num_from_name "${team}")"
  [[ -n "${n}" ]] || die "Team name must end with digits (e.g., team01). Got: ${team}"

  local uid gid port
  uid="$((DEFAULT_UID_BASE + n))"
  gid="$((DEFAULT_UID_BASE + n))"
  port="$((DEFAULT_PORT_BASE + n))"
  echo "${uid} ${gid} ${port}"
}

# -------------------------
# GPU mode
# -------------------------
get_gpu_mode(){
  if [[ -f "${GPU_MODE_FILE}" ]]; then
    cat "${GPU_MODE_FILE}"
  else
    echo "4"
  fi
}

set_gpu_mode(){
  local mode="$1"
  [[ "${mode}" == "4" || "${mode}" == "8" ]] || die "GPU mode must be 4 or 8."
  echo "${mode}" > "${GPU_MODE_FILE}"
  log "GPU mode set to ${mode} (file: ${GPU_MODE_FILE})"
}

validate_gpu_id(){
  local gpu="$1"
  [[ "${gpu}" =~ ^[0-9]+$ ]] || die "GPU must be numeric."
  local mode
  mode="$(get_gpu_mode)"
  if [[ "${mode}" == "4" ]]; then
    (( gpu >= 0 && gpu <= 3 )) || die "GPU must be 0..3 in 4-GPU mode."
  else
    (( gpu >= 0 && gpu <= 7 )) || die "GPU must be 0..7 in 8-GPU mode."
  fi
}

# -------------------------
# Compose YAML manipulation (simple + idempotent)
# -------------------------
compose_has_team(){
  local team="$1"
  grep -qE "^[[:space:]]{2}${team}:" "${COMPOSE_FILE}"
}

list_teams_from_compose(){
  # list service names (2-space indent under services:)
  awk '
    /^services:/ {in_services=1; next}
    in_services==1 && /^[ ]{2}[A-Za-z0-9._-]+:/ {
      s=$0; sub(/^  /,"",s); sub(/:.*/,"",s); print s
    }
  ' "${COMPOSE_FILE}"
}

compose_remove_team(){
  local team="$1"
  compose_has_team "${team}" || return 0

  # Remove block starting at "  team:" until next "  <name>:" or EOF
  awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0==team {blk=1; next}
    blk==1 && $0 ~ /^  [A-Za-z0-9._-]+:/ {blk=0}
    blk==0 {print}
  ' "${COMPOSE_FILE}" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "${COMPOSE_FILE}"
}

compose_append_team_block(){
  local block="$1"
  printf "\n%s\n" "${block}" >> "${COMPOSE_FILE}"
}

# -------------------------
# Parse env from compose (mawk-safe)
# output: UID GID PORT GPU
# -------------------------
get_team_env_from_compose(){
  local team="$1"
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local uid gid port gpu

  uid="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0==team {blk=1; next}
    blk==1 && $0 ~ /^  [A-Za-z0-9._-]+:/ {blk=0}
    blk==1 && $0 ~ /PUID:/ {s=$0; sub(/.*PUID:[ ]*/,"",s); gsub(/"/,"",s); print s; exit}
  ' "${COMPOSE_FILE}")"

  gid="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0==team {blk=1; next}
    blk==1 && $0 ~ /^  [A-Za-z0-9._-]+:/ {blk=0}
    blk==1 && $0 ~ /PGID:/ {s=$0; sub(/.*PGID:[ ]*/,"",s); gsub(/"/,"",s); print s; exit}
  ' "${COMPOSE_FILE}")"

  port="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0==team {blk=1; next}
    blk==1 && $0 ~ /^  [A-Za-z0-9._-]+:/ {blk=0}
    blk==1 && $0 ~ /- "[0-9]+:22"/ {
      s=$0
      sub(/.*- "/,"",s)
      sub(/:22".*/,"",s)
      print s
      exit
    }
  ' "${COMPOSE_FILE}")"

  gpu="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0==team {blk=1; next}
    blk==1 && $0 ~ /^  [A-Za-z0-9._-]+:/ {blk=0}
    blk==1 && $0 ~ /device_ids:/ {
      s=$0
      sub(/.*\["/,"",s)
      sub(/"\].*/,"",s)
      print s
      exit
    }
  ' "${COMPOSE_FILE}")"

  echo "${uid:-} ${gid:-} ${port:-} ${gpu:-}"
}

# -------------------------
# SSH key directory and perms
# -------------------------
ensure_team_ssh_dir(){
  local team="$1" gid="$2"
  local d="${SSH_DIR}/${team}"
  mkdir -p "${d}"
  touch "${d}/authorized_keys"
  fix_team_ssh_perms "${team}" "${gid}"
}

ensure_team_hostkeys_dir() {
  local team="${1:?team required}"
  local hk_dir="${SSH_DIR}/${team}/hostkeys"

  mkdir -p "${hk_dir}"
  chown root:root "${hk_dir}"
  chmod 700 "${hk_dir}"
}

fix_team_ssh_perms(){
  local team="$1" gid="$2"
  local d="${SSH_DIR}/${team}"
  local f="${d}/authorized_keys"
  [[ -d "${d}" ]] || die "SSH dir not found: ${d}"

  chown -R root:"${gid}" "${d}" 2>/dev/null || true
  chmod 750 "${d}" 2>/dev/null || true
  [[ -f "${f}" ]] || touch "${f}"
  chown root:"${gid}" "${f}" 2>/dev/null || true
  chmod 640 "${f}" 2>/dev/null || true
}

add_key(){
  local team="$1" key="$2" gid="$3" port="${4:-}"
  ensure_team_ssh_dir "${team}" "${gid}"

  local f="${SSH_DIR}/${team}/authorized_keys"

  if grep -qF "${key}" "${f}" 2>/dev/null; then
    log "Key already present for ${team}."
  else
    echo "${key}" >> "${f}"
    log "Key added for ${team}."
  fi

  fix_team_ssh_perms "${team}" "${gid}"

  # bastion authorized_keys에도 등록 (port가 주어진 경우)
  if [[ -n "${port}" ]] && id -u "${JUMP_USER}" >/dev/null 2>&1; then
    add_bastion_key "${team}" "${port}" "${key}"
  elif [[ -n "${port}" ]]; then
    log "WARN: bastion user '${JUMP_USER}' not set up; skipping bastion key registration. Run: $0 bastion-init"
  fi
}

backup_keys(){
  local team="$1" out_dir="${2:-${SSH_BACKUP_DIR}}"
  local src="${SSH_DIR}/${team}/authorized_keys"
  [[ -f "${src}" ]] || die "authorized_keys not found: ${src}"
  mkdir -p "${out_dir}"
  local ts dest
  ts="$(date +%Y%m%d_%H%M%S)"
  dest="${out_dir}/${team}_authorized_keys_${ts}.bak"
  cp -a "${src}" "${dest}"
  chmod 600 "${dest}" 2>/dev/null || true
  log "Backed up: ${src} -> ${dest}"
}

# -------------------------
# Bastion (SSH jump host) management
# - 자기 서버용 bastion: jump 계정으로 외부 SSH 받아 같은 호스트의 팀 컨테이너로 ProxyJump
# - 정책: ForceCommand=nologin + AllowTcpForwarding=yes (Match User 블록에 일괄)
# - 키 단위 화이트리스트: permitopen="127.0.0.1:<team_port>"
# -------------------------
ensure_bastion_setup(){
  # idempotent: jump 계정 + .ssh 디렉터리 + sshd Match 블록 + sshd reload
  if ! id -u "${JUMP_USER}" >/dev/null 2>&1; then
    log "Creating bastion user '${JUMP_USER}' (shell=/usr/sbin/nologin)..."
    useradd -m -s /usr/sbin/nologin "${JUMP_USER}"
  fi

  # 셸이 nologin이 아니면 강제로 교정 (ForceCommand가 이중 안전장치지만 계정 셸도 nologin으로 통일)
  local cur_shell
  cur_shell="$(getent passwd "${JUMP_USER}" | awk -F: '{print $7}')"
  if [[ "${cur_shell}" != "/usr/sbin/nologin" ]]; then
    log "Fixing ${JUMP_USER} shell: ${cur_shell} -> /usr/sbin/nologin"
    usermod -s /usr/sbin/nologin "${JUMP_USER}"
  fi

  mkdir -p "${JUMP_SSH_DIR}"
  chown "${JUMP_USER}:${JUMP_USER}" "${JUMP_SSH_DIR}"
  chmod 700 "${JUMP_SSH_DIR}"
  [[ -f "${JUMP_AUTHKEYS}" ]] || touch "${JUMP_AUTHKEYS}"
  chown "${JUMP_USER}:${JUMP_USER}" "${JUMP_AUTHKEYS}"
  chmod 600 "${JUMP_AUTHKEYS}"

  # sshd Match block — 멱등하게 항상 재기록 (관리자가 손댄 흔적이 있으면 백업 후 덮어씀)
  if [[ -f "${JUMP_SSHD_CONF}" ]] && ! cmp -s "${JUMP_SSHD_CONF}" <(_bastion_sshd_conf_content); then
    local bak="${JUMP_SSHD_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a "${JUMP_SSHD_CONF}" "${bak}"
    log "Existing ${JUMP_SSHD_CONF} backed up to ${bak}"
  fi
  _bastion_sshd_conf_content > "${JUMP_SSHD_CONF}"
  chmod 644 "${JUMP_SSHD_CONF}"

  # reload sshd
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || \
      log "WARN: failed to reload sshd; please reload manually."
  fi

  log "Bastion ready: ${JUMP_USER}@$(hostname) | sshd Match block applied (${JUMP_SSHD_CONF})."
}

_bastion_sshd_conf_content(){
  cat <<EOF
# Managed by teamctl-xfs.sh — bastion (SSH jump) policy for ${JUMP_USER}
Match User ${JUMP_USER}
    ForceCommand /usr/sbin/nologin
    AllowTcpForwarding yes
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
    GatewayPorts no
EOF
}

# Build a single authorized_keys line for bastion, prepending permitopen="..."
# Handles both raw key lines and lines that already have options.
_bastion_line_for(){
  local port="$1" key_line="$2"
  if [[ "${key_line}" =~ ^(ssh-|ecdsa-|sk-) ]]; then
    echo "permitopen=\"127.0.0.1:${port}\" ${key_line}"
  else
    # 기존 옵션이 앞에 있으면 콤마로 병합
    local opts rest
    opts="${key_line%% *}"
    rest="${key_line#* }"
    echo "permitopen=\"127.0.0.1:${port}\",${opts} ${rest}"
  fi
}

add_bastion_key(){
  local team="$1" port="$2" key="$3"
  id -u "${JUMP_USER}" >/dev/null 2>&1 || die "Bastion user '${JUMP_USER}' missing. Run: $0 bastion-init"
  [[ -n "${port}" ]] || die "Bastion port required for ${team}."

  [[ -f "${JUMP_AUTHKEYS}" ]] || { touch "${JUMP_AUTHKEYS}"; chown "${JUMP_USER}:${JUMP_USER}" "${JUMP_AUTHKEYS}"; chmod 600 "${JUMP_AUTHKEYS}"; }

  local line
  line="$(_bastion_line_for "${port}" "${key}")"

  # 같은 키 본문이 이미 같은 port permitopen으로 등록되어 있으면 skip
  if grep -F "permitopen=\"127.0.0.1:${port}\"" "${JUMP_AUTHKEYS}" 2>/dev/null | grep -qF "${key}"; then
    log "Bastion key already present for ${team} (port ${port})."
  else
    echo "${line}" >> "${JUMP_AUTHKEYS}"
    log "Bastion key added for ${team} (permitopen=127.0.0.1:${port})."
  fi
  chown "${JUMP_USER}:${JUMP_USER}" "${JUMP_AUTHKEYS}" 2>/dev/null || true
  chmod 600 "${JUMP_AUTHKEYS}" 2>/dev/null || true
}

remove_bastion_keys_for_team(){
  # team의 port에 해당하는 permitopen 라인을 모두 제거
  local team="$1" port="$2"
  [[ -f "${JUMP_AUTHKEYS}" ]] || return 0
  [[ -n "${port}" ]] || { log "WARN: no port for ${team}; bastion lines not cleaned."; return 0; }
  local pattern="permitopen=\"127.0.0.1:${port}\""
  if grep -qF "${pattern}" "${JUMP_AUTHKEYS}" 2>/dev/null; then
    grep -vF "${pattern}" "${JUMP_AUTHKEYS}" > "${JUMP_AUTHKEYS}.tmp" || true
    mv "${JUMP_AUTHKEYS}.tmp" "${JUMP_AUTHKEYS}"
    chown "${JUMP_USER}:${JUMP_USER}" "${JUMP_AUTHKEYS}" 2>/dev/null || true
    chmod 600 "${JUMP_AUTHKEYS}" 2>/dev/null || true
    log "Bastion keys for ${team} (port ${port}) removed."
  fi
}

sync_bastion_keys_all_teams(){
  # 모든 팀의 authorized_keys를 읽어 bastion authorized_keys를 재구축 (마이그레이션용)
  ensure_bastion_setup
  local tmp="${JUMP_AUTHKEYS}.new"
  : > "${tmp}"
  chown "${JUMP_USER}:${JUMP_USER}" "${tmp}"
  chmod 600 "${tmp}"

  local count=0 team team_keys_file uid gid port gpu
  while read -r team; do
    [[ -n "${team}" ]] || continue
    team_keys_file="${SSH_DIR}/${team}/authorized_keys"
    [[ -f "${team_keys_file}" ]] || continue
    read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"
    [[ -n "${port}" ]] || { log "Skip ${team}: no port in compose"; continue; }
    while IFS= read -r key_line; do
      [[ -n "${key_line}" && ! "${key_line}" =~ ^# ]] || continue
      _bastion_line_for "${port}" "${key_line}" >> "${tmp}"
      count=$((count + 1))
    done < "${team_keys_file}"
  done < <(list_teams_from_compose)

  mv "${tmp}" "${JUMP_AUTHKEYS}"
  chown "${JUMP_USER}:${JUMP_USER}" "${JUMP_AUTHKEYS}"
  chmod 600 "${JUMP_AUTHKEYS}"
  log "Bastion synced: ${count} key line(s) registered from all teams."
}

# -------------------------
# XFS project quota (local)
# -------------------------
ensure_xfs_prjquota(){
  command -v xfs_quota >/dev/null 2>&1 || die "xfs_quota not found. Install xfsprogs."
  [[ -d "${DATA_ROOT}" ]] || die "${DATA_ROOT} not found."
  mountpoint -q "${DATA_ROOT}" || die "${DATA_ROOT} is not a mountpoint. Mount XFS disk to ${DATA_ROOT} first."

  local fstype
  fstype="$(stat -f -c %T "${DATA_ROOT}")"
  [[ "${fstype}" == "xfs" ]] || die "${DATA_ROOT} is not XFS (stat reports ${fstype})."

  xfs_quota -x -c "state" "${DATA_ROOT}" >/dev/null 2>&1 || die "xfs_quota state failed. Is prjquota enabled on ${DATA_ROOT} mount?"
}

ensure_proj_files(){
  touch "${PROJECTS_FILE}" "${PROJID_FILE}"
}

ensure_project_mapping(){
  local team="$1" projid="$2" path="$3"

  ensure_xfs_prjquota
  ensure_proj_files

  if ! grep -qE "^${team}:" "${PROJID_FILE}"; then
    echo "${team}:${projid}" >> "${PROJID_FILE}"
  else
    local cur
    cur="$(awk -F: -v t="${team}" '$1==t{print $2; exit}' "${PROJID_FILE}" || true)"
    [[ -z "${cur}" || "${cur}" == "${projid}" ]] || die "projid mismatch for ${team} (have ${cur}, want ${projid})"
  fi

  if ! grep -qE "^${projid}:" "${PROJECTS_FILE}"; then
    echo "${projid}:${path}" >> "${PROJECTS_FILE}"
  else
    local curp
    curp="$(awk -F: -v id="${projid}" '$1==id{print $2; exit}' "${PROJECTS_FILE}" || true)"
    [[ -z "${curp}" || "${curp}" == "${path}" ]] || die "project id ${projid} already mapped to ${curp} (want ${path})"
  fi

  xfs_quota -x -c "project -s ${team}" "${DATA_ROOT}" >/dev/null
}

set_team_quota(){
  local team="$1" soft="$2" hard="$3"
  xfs_quota -x -c "limit -p bsoft=${soft} bhard=${hard} ${team}" "${DATA_ROOT}" >/dev/null
}

report_team_quota(){
  local team="$1"
  xfs_quota -x -c "report -p -n" "${DATA_ROOT}" | sed -n "1,3p;/${team}/p"
}

purge_team_xfs_project(){
  local team="$1" gid="$2"
  ensure_proj_files
  xfs_quota -x -c "limit -p bsoft=0 bhard=0 ${team}" "${DATA_ROOT}" >/dev/null 2>&1 || true

  awk -F: -v id="${gid}" '$1!=id{print}' "${PROJECTS_FILE}" > "${PROJECTS_FILE}.tmp" && mv "${PROJECTS_FILE}.tmp" "${PROJECTS_FILE}"
  awk -F: -v t="${team}" '$1!=t{print}' "${PROJID_FILE}" > "${PROJID_FILE}.tmp" && mv "${PROJID_FILE}.tmp" "${PROJID_FILE}"
}

# -------------------------
# NFS (host mount) checks
# -------------------------
ensure_nfs_mount(){
  [[ "${NFS_ENABLED}" == "true" ]] || return 0
  [[ -d "${NFS_MOUNT}" ]] || die "NFS_MOUNT not found: ${NFS_MOUNT}"
  mountpoint -q "${NFS_MOUNT}" || die "NFS_MOUNT is not a mountpoint: ${NFS_MOUNT}"
}

# -------------------------
# Remote NFS quota (storage server via ssh)
# -------------------------
ssh_nfs(){
  local cmd="$1"
  need_cmd ssh
  local key_opt=()
  if [[ -n "${NFS_SSH_KEY:-}" ]]; then
    key_opt=(-i "${NFS_SSH_KEY}")
  fi

  ssh -p "${NFS_SSH_PORT}" \
    "${key_opt[@]}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=5 \
    "${NFS_SSH_USER}@${NFS_HOST}" \
    "${cmd}"
}

ensure_remote_nfsctl(){
  ssh_nfs "test -x ${NFSCTL_REMOTE_PATH} || { echo 'no nfsctl: ${NFSCTL_REMOTE_PATH}'; exit 2; }"
}

ensure_team_nfs_remote(){
  # idempotent: if team exists -> resize, else create
  local team="$1" uid="$2" gid="$3" soft="$4" hard="$5"
  ensure_nfs_mount
  ensure_remote_nfsctl

  ssh_nfs "sudo ${NFSCTL_REMOTE_PATH} who ${team} >/dev/null 2>&1 && \
           sudo ${NFSCTL_REMOTE_PATH} resize ${team} --soft ${soft} --hard ${hard} || \
           sudo ${NFSCTL_REMOTE_PATH} create ${team} --uid ${uid} --gid ${gid} --soft ${soft} --hard ${hard}"
}

ensure_team_nfs_remote_remove(){
  # remove mapping/quota on storage server, optional purge dir
  local team="$1" purge_dir="$2"   # purge_dir: true|false
  ensure_remote_nfsctl

  local cmd="sudo ${NFSCTL_REMOTE_PATH} remove ${team}"
  if [[ "${purge_dir}" == "true" ]]; then
    cmd="${cmd} --purge-dir"
  fi

  # nfsctl.sh remove는 idempotent하게 만들었지만, 실패해도 로컬 삭제는 계속 진행할 수 있게
  ssh_nfs "${cmd}" || {
    echo "WARN: remote NFS remove failed for ${team} (continuing)."
    return 0
  }
}

# -------------------------
# Team storage (local XFS quota + perms)
# -------------------------
prepare_team_storage(){
  local team="$1" uid="$2" gid="$3"
  local hard="${4:-${DEFAULT_TEAM_HARD}}"
  local soft="${5:-${DEFAULT_TEAM_SOFT}}"

  ensure_xfs_prjquota
  ensure_dirs

  mkdir -p "${TEAMS_DIR}/${team}"
  chown -R "${uid}:${gid}" "${TEAMS_DIR}/${team}" 2>/dev/null || true
  chmod 2770 "${TEAMS_DIR}/${team}" 2>/dev/null || true

  ensure_project_mapping "${team}" "${gid}" "${TEAMS_DIR}/${team}"
  set_team_quota "${team}" "${soft}" "${hard}"
}

# -------------------------
# Compose team block generator
# - /home/<team> shares same local volume as /workspace (local quota)
# - Optional NFS: /mnt/nfs/teams/<team> -> /nfs/team:rw
# -------------------------
render_team_block(){
  local team="$1" image="$2" gpu="$3" port="$4" uid="$5" gid="$6"
  local shm="${DEFAULT_SHM_SIZE}"
  local ipc="${DEFAULT_IPC}"

  local nfs_line=""
  if [[ "${NFS_ENABLED}" == "true" ]]; then
    nfs_line="      - ${NFS_MOUNT}/${team}:${NFS_CONTAINER_PATH}:rw"
  fi

  cat <<YAML
  ${team}:
    image: ${image}
    container_name: ${team}_gpu${gpu}
    restart: ${DEFAULT_RESTART}
    ports:
      - "${port}:22"
    volumes:
      - ${TEAMS_DIR}/${team}:/workspace
      - ${TEAMS_DIR}/${team}:/home/${team}
      - ${SSH_DIR}/${team}:/ssh-keys:ro
      - ${SSH_DIR}/${team}/hostkeys:/etc/ssh/hostkeys:rw
${nfs_line}
    environment:
      USER_NAME: ${team}
      PUID: "${uid}"
      PGID: "${gid}"
      ALLOW_SUDO: "${DEFAULT_ALLOW_SUDO}"
      SUDO_POLICY: "${DEFAULT_SUDO_POLICY}"
    shm_size: "${shm}"
    ipc: ${ipc}
    ulimits:
      memlock: -1
      stack: 67108864
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["${gpu}"]
              capabilities: ["gpu"]
YAML
}

# -------------------------
# Commands
# -------------------------
usage(){
  cat <<EOF
Usage: sudo $0 <command> [args...]

Core:
  sudo $0 set-gpu-mode 4|8
  sudo $0 create TEAM --gpu N [--image IMG] [--port P] [--uid U] [--gid G] \
    [--size 300G] [--soft 290G] \
    [--nfs] [--nfs-size 1000G] [--nfs-soft 950G] \
    [--nfs-host HOST] [--nfs-user USER] [--nfs-port 22] [--nfs-key /path/to/key] [--nfsctl /opt/nfs/nfsctl.sh] \
    [--nfs-mount /mnt/nfs/teams] [--nfs-path /nfs/team]
  sudo $0 add-key TEAM --key "ssh-ed25519 AAAA... team01/user"
  sudo $0 fix-perms TEAM
  sudo $0 audit
  sudo $0 list-mounts
  sudo $0 backup-keys TEAM [--out DIR]
  sudo $0 resize TEAM --size 500G [--soft 490G]              (LOCAL quota only)
  sudo $0 nfs-resize TEAM --nfs-size 1000G [--nfs-soft 950G] (NFS quota only)
  sudo $0 reset TEAM
  sudo $0 remove TEAM [--purge-data] [--purge-nfs] [--purge-nfs-dir] \
    [--nfs-host HOST] [--nfs-user USER] [--nfs-port 22] [--nfs-key /path/to/key] [--nfsctl /opt/nfs/nfsctl.sh]
  sudo $0 set-image TEAM image:tag

Bastion (SSH gateway: jump user on this host):
  sudo $0 bastion-init                  # 한번 실행: jump 계정 + sshd Match 블록 셋업
  sudo $0 bastion-sync                  # 마이그레이션: 모든 팀 키를 jump authorized_keys에 재등록
  sudo $0 bastion-list                  # 현재 jump authorized_keys 내용 확인

Storage model:
- Local quota: ${DATA_ROOT} (XFS + prjquota). Team local dir: ${TEAMS_DIR}/<team>
  - Container: /workspace and /home/<team> share the same local dir (same local quota)
- NFS (optional): storage server quota + host mount ${NFS_MOUNT_DEFAULT}/<team> -> container ${NFS_CONTAINER_PATH_DEFAULT}
  - NFS quota is independent from local quota.

Bastion model:
- External SSH access: only ${JUMP_USER}@<this-host>:22 is exposed externally.
- Students use ProxyJump to reach their team container via 127.0.0.1:<team_port> (bastion-side).
- Per-key 'permitopen' restricts each student key to their own team port only.
- 'add-key' and 'remove' auto-sync to ${JUMP_AUTHKEYS}.

EOF
}

cmd_set_gpu_mode(){
  need_root
  ensure_dirs
  local mode="${1:-}"
  [[ -n "${mode}" ]] || die "Provide 4 or 8."
  set_gpu_mode "${mode}"
}

cmd_create(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  [[ "${team}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid team name."

  local gpu="" image="${DEFAULT_IMAGE}" port="" uid="" gid=""
  local size="${DEFAULT_TEAM_HARD}" soft="${DEFAULT_TEAM_SOFT}"

  # NFS flags/options
  local nfs="false"
  local nfs_size="" nfs_soft=""
  local nfs_host="${NFS_HOST_DEFAULT}"
  local nfs_user="${NFS_SSH_USER_DEFAULT}"
  local nfs_port="${NFS_SSH_PORT_DEFAULT}"
  local nfs_key="${NFS_SSH_KEY_DEFAULT}"
  local nfsctl="${NFSCTL_REMOTE_PATH_DEFAULT}"
  local nfs_mount="${NFS_MOUNT_DEFAULT}"
  local nfs_path="${NFS_CONTAINER_PATH_DEFAULT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gpu) gpu="${2:-}"; shift 2;;
      --image) image="${2:-}"; shift 2;;
      --port) port="${2:-}"; shift 2;;
      --uid) uid="${2:-}"; shift 2;;
      --gid) gid="${2:-}"; shift 2;;
      --size) size="${2:-}"; shift 2;;
      --soft) soft="${2:-}"; shift 2;;

      --nfs) nfs="true"; shift 1;;
      --nfs-size) nfs_size="${2:-}"; shift 2;;
      --nfs-soft) nfs_soft="${2:-}"; shift 2;;
      --nfs-host) nfs_host="${2:-}"; shift 2;;
      --nfs-user) nfs_user="${2:-}"; shift 2;;
      --nfs-port) nfs_port="${2:-}"; shift 2;;
      --nfs-key) nfs_key="${2:-}"; shift 2;;
      --nfsctl) nfsctl="${2:-}"; shift 2;;
      --nfs-mount) nfs_mount="${2:-}"; shift 2;;
      --nfs-path) nfs_path="${2:-}"; shift 2;;

      *) die "Unknown arg: $1";;
    esac
  done

  [[ -n "${gpu}" ]] || die "--gpu N required."
  validate_gpu_id "${gpu}"

  if compose_has_team "${team}"; then
    die "Team already exists in compose: ${team}"
  fi

  if [[ -z "${uid}" || -z "${gid}" || -z "${port}" ]]; then
    read -r duid dgid dport <<< "$(default_ids_for_team "${team}")"
    uid="${uid:-${duid}}"
    gid="${gid:-${dgid}}"
    port="${port:-${dport}}"
  fi

  [[ "${uid}" =~ ^[0-9]+$ ]] || die "UID must be numeric."
  [[ "${gid}" =~ ^[0-9]+$ ]] || die "GID must be numeric."
  [[ "${port}" =~ ^[0-9]+$ ]] || die "Port must be numeric."

  # Local quota workspace
  prepare_team_storage "${team}" "${uid}" "${gid}" "${size}" "${soft}"

  # SSH dirs
  ensure_team_ssh_dir "${team}" "${gid}"
  ensure_team_hostkeys_dir "${team}"

  # NFS settings (only if --nfs)
  if [[ "${nfs}" == "true" ]]; then
    NFS_ENABLED="true"
    NFS_HOST="${nfs_host}"
    NFS_SSH_USER="${nfs_user}"
    NFS_SSH_PORT="${nfs_port}"
    NFS_SSH_KEY="${nfs_key}"
    NFSCTL_REMOTE_PATH="${nfsctl}"
    NFS_MOUNT="${nfs_mount}"
    NFS_CONTAINER_PATH="${nfs_path}"

    # if not provided, default to local quota values
    nfs_size="${nfs_size:-${size}}"
    nfs_soft="${nfs_soft:-${soft}}"

    ensure_team_nfs_remote "${team}" "${uid}" "${gid}" "${nfs_soft}" "${nfs_size}"
  else
    NFS_ENABLED="false"
    NFS_MOUNT="${nfs_mount}"
    NFS_CONTAINER_PATH="${nfs_path}"
  fi

  local block
  block="$(render_team_block "${team}" "${image}" "${gpu}" "${port}" "${uid}" "${gid}")"
  compose_append_team_block "${block}"

  log "Created team ${team}: gpu=${gpu}, port=${port}, uid=${uid}, gid=${gid}"
  log "Local quota: soft=${soft} hard=${size}  dir=${TEAMS_DIR}/${team}  (container: /workspace + /home/${team})"
  if [[ "${NFS_ENABLED}" == "true" ]]; then
    log "NFS quota:   soft=${nfs_soft} hard=${nfs_size}  host=${NFS_MOUNT}/${team}  (container: ${NFS_CONTAINER_PATH})"
    log "NFS remote:  ${NFS_SSH_USER}@${NFS_HOST}:${NFSCTL_REMOTE_PATH}"
  fi
  log "SSH keys:    ${SSH_DIR}/${team}/authorized_keys"
  log "Next: docker compose -f ${COMPOSE_FILE} up -d ${team}"
}

cmd_nfs_resize(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local nfs_size="" nfs_soft=""
  local nfs_host="${NFS_HOST_DEFAULT}"
  local nfs_user="${NFS_SSH_USER_DEFAULT}"
  local nfs_port="${NFS_SSH_PORT_DEFAULT}"
  local nfs_key="${NFS_SSH_KEY_DEFAULT}"
  local nfsctl="${NFSCTL_REMOTE_PATH_DEFAULT}"
  local nfs_mount="${NFS_MOUNT_DEFAULT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nfs-size) nfs_size="${2:-}"; shift 2;;
      --nfs-soft) nfs_soft="${2:-}"; shift 2;;
      --nfs-host) nfs_host="${2:-}"; shift 2;;
      --nfs-user) nfs_user="${2:-}"; shift 2;;
      --nfs-port) nfs_port="${2:-}"; shift 2;;
      --nfs-key) nfs_key="${2:-}"; shift 2;;
      --nfsctl) nfsctl="${2:-}"; shift 2;;
      --nfs-mount) nfs_mount="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done

  [[ -n "${nfs_size}" ]] || die "--nfs-size NEW_SIZE required (e.g., 1000G)."
  [[ -n "${nfs_soft}" ]] || nfs_soft="${nfs_size}"

  read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"
  [[ -n "${uid}" && -n "${gid}" ]] || die "Could not determine UID/GID from compose."

  NFS_ENABLED="true"
  NFS_HOST="${nfs_host}"
  NFS_SSH_USER="${nfs_user}"
  NFS_SSH_PORT="${nfs_port}"
  NFS_SSH_KEY="${nfs_key}"
  NFSCTL_REMOTE_PATH="${nfsctl}"
  NFS_MOUNT="${nfs_mount}"

  ensure_team_nfs_remote "${team}" "${uid}" "${gid}" "${nfs_soft}" "${nfs_size}"
  log "NFS quota updated for ${team}: soft=${nfs_soft} hard=${nfs_size}"
}

cmd_add_key(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key) key="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done
  [[ -n "${key}" ]] || die "--key \"ssh-...\" required."

  read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"
  [[ -n "${gid}" ]] || die "Could not determine GID from compose for ${team}"
  [[ -n "${port}" ]] || die "Could not determine port from compose for ${team}"

  add_key "${team}" "${key}" "${gid}" "${port}"
  log "Done."
}

cmd_fix_perms(){
  need_root
  ensure_dirs
  need_compose
  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"
  [[ -n "${gid}" ]] || die "Could not determine GID."

  fix_team_ssh_perms "${team}" "${gid}"
  log "Fixed SSH perms for ${team} (root:${gid}, 750/640)."
}

cmd_backup_keys(){
  need_root
  ensure_dirs
  need_compose
  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local out="${SSH_BACKUP_DIR}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done
  backup_keys "${team}" "${out}"
}

cmd_list_mounts(){
  need_root
  ensure_dirs
  need_compose

  log "== teamctl list-mounts =="
  log "- Local data root: ${DATA_ROOT}"
  log "- Local teams dir: ${TEAMS_DIR}"
  log "- NFS mount (host): ${NFS_MOUNT_DEFAULT} (if enabled per team via --nfs)"
  echo ""

  printf "%-10s %-28s %-8s %-8s %-8s %-8s\n" "TEAM" "LOCAL_PATH" "SIZE" "USED" "AVAIL" "USE%"
  printf "%-10s %-28s %-8s %-8s %-8s %-8s\n" "----------" "----------------------------" "--------" "--------" "--------" "--------"

  local teams
  teams="$(list_teams_from_compose || true)"
  if [[ -z "${teams}" ]]; then
    log "No teams found in compose."
    return 0
  fi

  while read -r t; do
    [[ -n "${t}" ]] || continue
    local mnt="${TEAMS_DIR}/${t}"
    if [[ -d "${mnt}" ]]; then
      local line size used avail usep
      line="$(df -h "${mnt}" 2>/dev/null | awk 'NR==2{print $2,$3,$4,$5}' || true)"
      if [[ -n "${line}" ]]; then
        read -r size used avail usep <<< "${line}"
        printf "%-10s %-28s %-8s %-8s %-8s %-8s\n" "${t}" "${mnt}" "${size}" "${used}" "${avail}" "${usep}"
      else
        printf "%-10s %-28s %-8s %-8s %-8s %-8s\n" "${t}" "${mnt}" "-" "-" "-" "-"
      fi
    else
      printf "%-10s %-28s %-8s %-8s %-8s %-8s\n" "${t}" "${mnt}" "MISSING" "-" "-" "-"
    fi
  done <<< "${teams}"
}

cmd_audit(){
  need_root
  ensure_dirs
  need_compose

  log "== teamctl audit =="
  log "- GPU mode: $(get_gpu_mode) (file: ${GPU_MODE_FILE})"
  log "- Compose: ${COMPOSE_FILE}"
  log "- Local:  ${TEAMS_DIR} (quota via XFS prjquota on ${DATA_ROOT})"
  log "- NFS host mount: ${NFS_MOUNT_DEFAULT} (per-team enabled via --nfs)"
  echo ""

  printf "%-8s %-4s %-6s %-6s %-6s %-10s %-6s %-s\n" "TEAM" "GPU" "PORT" "UID" "GID" "SSH_DIR_OK" "AK_OK" "NOTES"
  printf "%-8s %-4s %-6s %-6s %-6s %-10s %-6s %-s\n" "-----" "---" "-----" "-----" "-----" "----------" "-----" "-----"

  local teams
  teams="$(list_teams_from_compose || true)"
  [[ -n "${teams}" ]] || { log "No teams found."; return 0; }

  while read -r team; do
    [[ -n "${team}" ]] || continue
    read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"

    local notes=""
    local ssh_ok="NO" ak_ok="NO"

    local sshd="${SSH_DIR}/${team}"
    local ak="${sshd}/authorized_keys"

    [[ -d "${sshd}" ]] && ssh_ok="YES"
    [[ -f "${ak}" ]] && ak_ok="YES"

    local downer fowner
    downer="$(stat -c "%u:%g" "${sshd}" 2>/dev/null || echo "?")"
    fowner="$(stat -c "%u:%g" "${ak}" 2>/dev/null || echo "?")"

    if [[ "${downer}" != "0:${gid}" ]]; then notes+="SSH_DIR_OWNER(${downer}) "; fi
    if [[ "${fowner}" != "0:${gid}" ]]; then notes+="AK_OWNER(${fowner}) "; fi

    local dperm fperm
    dperm="$(stat -c "%a" "${sshd}" 2>/dev/null || echo "?")"
    fperm="$(stat -c "%a" "${ak}" 2>/dev/null || echo "?")"
    if [[ "${dperm}" != "750" ]]; then notes+="SSH_DIR_PERM(${dperm}) "; fi
    if [[ "${fperm}" != "640" ]]; then notes+="AK_PERM(${fperm}) "; fi

    # NFS dir existence check (host side)
    if mountpoint -q "${NFS_MOUNT_DEFAULT}" 2>/dev/null; then
      [[ -d "${NFS_MOUNT_DEFAULT}/${team}" ]] || notes+="NFS_DIR_MISSING "
    else
      notes+="NFS_NOT_MOUNTED "
    fi

    printf "%-8s %-4s %-6s %-6s %-6s %-10s %-6s %-s\n" \
      "${team}" "${gpu:-?}" "${port:-?}" "${uid:-?}" "${gid:-?}" "${ssh_ok}" "${ak_ok}" "${notes}"
  done <<< "${teams}"

  echo ""
  echo "Tips:"
  echo "- Fix perms: sudo $0 fix-perms TEAM"
  echo "- Local quota report: sudo xfs_quota -x -c 'report -p -n' ${DATA_ROOT}"
  echo "- NFS per team (host): ${NFS_MOUNT_DEFAULT}/<team>  (container: ${NFS_CONTAINER_PATH_DEFAULT})"
}

cmd_resize(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local size="" soft=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --size) size="${2:-}"; shift 2;;
      --soft) soft="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done
  [[ -n "${size}" ]] || die "--size NEW_SIZE required (e.g., 500G)."

  read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"
  [[ -n "${gid}" ]] || die "Could not determine GID."

  ensure_project_mapping "${team}" "${gid}" "${TEAMS_DIR}/${team}"

  if [[ -z "${soft}" ]]; then
    soft="${size}"
    if [[ "${size}" =~ ^([0-9]+)G$ ]]; then
      local n="${BASH_REMATCH[1]}"
      if (( n > 20 )); then soft="$((n-10))G"; fi
    fi
  fi

  set_team_quota "${team}" "${soft}" "${size}"
  log "Local quota updated for ${team}: soft=${soft} hard=${size}"
  report_team_quota "${team}"
  log "NOTE: This changes LOCAL quota only. Use '$0 nfs-resize' for NFS quota."
}

cmd_reset(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  docker compose -f "${COMPOSE_FILE}" stop "${team}" >/dev/null 2>&1 || true
  docker compose -f "${COMPOSE_FILE}" rm -s -f "${team}" >/dev/null 2>&1 || true
  log "Reset container for ${team}. Data preserved."
  log "Next: docker compose -f ${COMPOSE_FILE} up -d ${team}"
}

cmd_remove(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found: ${team}"

  # new options
  local purge="false"
  local purge_nfs="false"
  local purge_nfs_dir="false"

  # remote NFS options (allow override on remove too)
  local nfs_host="${NFS_HOST_DEFAULT}"
  local nfs_user="${NFS_SSH_USER_DEFAULT}"
  local nfs_port="${NFS_SSH_PORT_DEFAULT}"
  local nfs_key="${NFS_SSH_KEY_DEFAULT}"
  local nfsctl="${NFSCTL_REMOTE_PATH_DEFAULT}"
  local nfs_mount="${NFS_MOUNT_DEFAULT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge-data) purge="true"; shift 1;;
      --purge-nfs) purge_nfs="true"; shift 1;;
      --purge-nfs-dir) purge_nfs_dir="true"; shift 1;;

      --nfs-host) nfs_host="${2:-}"; shift 2;;
      --nfs-user) nfs_user="${2:-}"; shift 2;;
      --nfs-port) nfs_port="${2:-}"; shift 2;;
      --nfs-key) nfs_key="${2:-}"; shift 2;;
      --nfsctl) nfsctl="${2:-}"; shift 2;;
      --nfs-mount) nfs_mount="${2:-}"; shift 2;;

      *) die "Unknown arg: $1";;
    esac
  done

  # container stop/rm
  docker compose -f "${COMPOSE_FILE}" stop "${team}" >/dev/null 2>&1 || true
  docker compose -f "${COMPOSE_FILE}" rm -s -f "${team}" >/dev/null 2>&1 || true

  # get env before removing compose block
  local uid gid port gpu
  read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"

  # remove from compose
  compose_remove_team "${team}"
  log "Removed ${team} from compose."

  # Always clean bastion authorized_keys entries for this team
  if [[ -n "${port:-}" ]]; then
    remove_bastion_keys_for_team "${team}" "${port}" || true
  else
    log "WARN: no port detected for ${team}; bastion lines may need manual cleanup."
  fi

  # Optionally purge local data
  if [[ "${purge}" == "true" ]]; then
    # backup authorized_keys
    if [[ -f "${SSH_DIR}/${team}/authorized_keys" ]]; then
      backup_keys "${team}" "${SSH_BACKUP_DIR}" || true
    fi

    # remove local XFS quota mapping + data
    if [[ -n "${gid:-}" ]]; then
      purge_team_xfs_project "${team}" "${gid}" || true
    fi
    rm -rf "${TEAMS_DIR:?}/${team}" || true
    rm -rf "${SSH_DIR:?}/${team}" || true
    log "Purged LOCAL data for ${team}."
  else
    log "Local data preserved (use --purge-data to delete local):"
    log "- local workspace: ${TEAMS_DIR}/${team}"
    log "- ssh keys:        ${SSH_DIR}/${team}"
  fi

  # Optionally purge NFS remotely (mapping/quota, optionally dir)
  # NOTE: This runs only when user explicitly asks (--purge-nfs), regardless of --purge-data.
  if [[ "${purge_nfs}" == "true" ]]; then
    # set remote context
    NFS_ENABLED="true"
    NFS_HOST="${nfs_host}"
    NFS_SSH_USER="${nfs_user}"
    NFS_SSH_PORT="${nfs_port}"
    NFS_SSH_KEY="${nfs_key}"
    NFSCTL_REMOTE_PATH="${nfsctl}"
    NFS_MOUNT="${nfs_mount}"

    # If user asked to delete NFS dir too, ensure mount exists (helps avoid surprises) but still allow remote remove.
    if mountpoint -q "${NFS_MOUNT}" 2>/dev/null; then
      log "Host NFS mount OK: ${NFS_MOUNT}"
    else
      log "WARN: Host NFS mount not detected at ${NFS_MOUNT} (continuing remote remove anyway)."
    fi

    ensure_team_nfs_remote_remove "${team}" "${purge_nfs_dir}"
    if [[ "${purge_nfs_dir}" == "true" ]]; then
      log "Purged NFS mapping/quota + directory for ${team} (remote)."
    else
      log "Purged NFS mapping/quota for ${team} (remote). Directory preserved."
    fi
  else
    log "NFS preserved (use --purge-nfs to remove NFS quota/mapping; add --purge-nfs-dir to delete NFS dir)."
  fi
}

cmd_bastion_init(){
  need_root
  ensure_bastion_setup
}

cmd_bastion_sync(){
  need_root
  need_compose
  sync_bastion_keys_all_teams
}

cmd_bastion_list(){
  need_root
  [[ -f "${JUMP_AUTHKEYS}" ]] || die "Bastion not set up. Run: $0 bastion-init"
  echo "# Bastion: ${JUMP_USER}@$(hostname) | ${JUMP_AUTHKEYS}"
  echo "# (한 줄당: permitopen=\"127.0.0.1:<port>\" <key-type> <key-data> <comment>)"
  echo "---"
  cat "${JUMP_AUTHKEYS}"
}

cmd_set_image() {
  local team="${1:-}"
  local image="${2:-}"
  local compose="${COMPOSE_FILE:-/opt/mlops/compose.yaml}"

  if [[ -z "$team" || -z "$image" ]]; then
    echo "Usage: $0 set-image TEAM image:tag"
    return 2
  fi
  if [[ ! -f "$compose" ]]; then
    echo "ERROR: compose file not found: $compose"
    return 1
  fi

  local tmp
  tmp="$(mktemp)"

  awk -v TEAM="$team" -v NEWIMG="$image" '
    BEGIN { in_services=0; in_team=0; updated=0 }

    /^services:[[:space:]]*$/ { in_services=1; print; next }

    in_services && match($0, /^[[:space:]]{2}([A-Za-z0-9_.-]+):[[:space:]]*$/, m) {
      in_team = (m[1] == TEAM)
      print
      next
    }

    in_services && in_team && $0 ~ /^[[:space:]]{4}image:[[:space:]]*/ {
      print "    image: " NEWIMG
      updated=1
      next
    }

    { print }

    END { if (updated == 0) exit 3 }
  ' "$compose" > "$tmp"

  local rc=$?
  if [[ $rc -eq 0 ]]; then
    sudo mv "$tmp" "$compose"
    echo "Updated image for ${team} -> ${image}"
    echo "Next: sudo docker compose -f ${compose} up -d --no-deps --force-recreate ${team}"
    return 0
  elif [[ $rc -eq 3 ]]; then
    rm -f "$tmp"
    echo "ERROR: Could not find service '${team}' or its image line in ${compose}"
    return 1
  else
    rm -f "$tmp"
    echo "ERROR: Failed to update compose (awk exit $rc)"
    return 1
  fi
}

# -------------------------
# Main
# -------------------------
main(){
  local cmd="${1:-}"
  shift || true

  case "${cmd}" in
    set-gpu-mode) cmd_set_gpu_mode "$@";;
    create) cmd_create "$@";;
    add-key) cmd_add_key "$@";;
    fix-perms) cmd_fix_perms "$@";;
    audit) cmd_audit;;
    list-mounts) cmd_list_mounts;;
    backup-keys) cmd_backup_keys "$@";;
    resize) cmd_resize "$@";;
    nfs-resize) cmd_nfs_resize "$@";;
    reset) cmd_reset "$@";;
    remove) cmd_remove "$@";;
    set-image) cmd_set_image "${1:-}" "${2:-}" ;;
    bastion-init) cmd_bastion_init "$@";;
    bastion-sync) cmd_bastion_sync "$@";;
    bastion-list) cmd_bastion_list "$@";;
    ""|-h|--help|help) usage;;
    *) die "Unknown command: ${cmd}. Use --help.";;
  esac
}

main "$@"