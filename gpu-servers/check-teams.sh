#!/usr/bin/env bash
set -euo pipefail

# =========================
# check-teams.sh — 팀 컨테이너 점검 (읽기 전용)
# 배포: /opt/mlops/check-teams.sh
#
# 용도: 서버 재기동/장애 복구 후 팀 컨테이너가 "올라왔는지"가 아니라
#       "제대로 올라왔는지"를 확인한다. 조교에게 맡겨도 안전하도록 읽기 전용.
#
# 확인 항목:
#   1. 컨테이너 실행 상태
#   2. GPU 인식 (nvidia-smi)      — 드라이버/DKMS 깨짐 탐지
#   3. /workspace                 — 로컬 XFS 프로젝트 쿼터
#   4. /nfs/team                  — NFS 마운트 여부 + 쿼터
#
# IMPORTANT:
# - 컨테이너 내부 명령은 반드시 `docker exec -u <team>` 로 실행한다.
#   Dockerfile에 USER 지시자가 없어 기본이 root인데, NFS export가 root_squash라
#   root는 nobody로 강등된다. 팀 디렉터리는 chmod 2770(others 권한 0)이므로
#   root로 실행하면 /nfs/team이 **항상** Permission denied로 나온다. 오진의 원인.
# - 대화형 셸(-it)로 들어가지 않으므로 학생 개인 파일을 열람하지 않는다.
# - NFS가 automount(x-systemd.automount) 트리거 전에 컨테이너가 뜨면 NFS 대신
#   빈 로컬 디렉터리가 바인드될 수 있다. 이 스크립트는 그 경우를 자동 탐지한다.
#
# 사용법:
#   ./check-teams.sh                 # 전체 팀
#   ./check-teams.sh team01 team02   # 특정 팀만
# =========================

COMPOSE_FILE="${COMPOSE_FILE:-/opt/mlops/compose.yaml}"
WORKSPACE_PATH="/workspace"
NFS_PATH="/nfs/team"

PROBLEMS=0

log(){ printf '%s\n' "$*"; }
warn(){ printf '  !! %s\n' "$*"; PROBLEMS=$((PROBLEMS+1)); }
indent(){ sed 's/^/    /'; }

list_team_containers(){
  docker ps -a --format '{{.Names}}' | grep -E '^team[0-9]{2}_' | sort || true
}

# df 결과를 출력한다. 소스(파일시스템) 필드는 전역 DF_SRC 로 돌려준다.
# ※ 표를 stdout으로 찍으므로 소스를 함께 반환할 수 없다(캡처 시 섞임) → 전역 사용.
DF_SRC=""
show_df(){
  local team="$1" cname="$2" path="$3" out
  DF_SRC=""
  if ! out="$(docker exec -u "${team}" "${cname}" df -h "${path}" 2>&1)"; then
    warn "${path} 확인 실패: ${out}"
    return 1
  fi
  printf '%s\n' "${out}" | tail -n +2 | indent
  DF_SRC="$(printf '%s' "${out}" | awk 'NR==2{print $1}')"
}

check_one(){
  local cname="$1"
  local team="${cname%%_*}"
  local status src out

  status="$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || echo unknown)"
  log ""
  log "════════════════ ${cname} ════════════════"
  log "  상태: ${status}"

  if [[ "${status}" != "running" ]]; then
    warn "실행 중이 아님 → sudo docker compose -f ${COMPOSE_FILE} up -d ${team}"
    return
  fi

  log "  ── GPU ──"
  if out="$(docker exec -u "${team}" "${cname}" nvidia-smi \
              --query-gpu=index,name,memory.used,memory.total,temperature.gpu \
              --format=csv,noheader 2>&1)"; then
    printf '%s\n' "${out}" | indent
  else
    printf '%s\n' "${out}" | indent
    warn "GPU 인식 실패 → 호스트에서 'nvidia-smi', 'dkms status', 'uname -r' 확인"
  fi

  log "  ── ${WORKSPACE_PATH} (로컬 XFS 쿼터) ──"
  show_df "${team}" "${cname}" "${WORKSPACE_PATH}" || true

  log "  ── ${NFS_PATH} (NFS) ──"
  if show_df "${team}" "${cname}" "${NFS_PATH}"; then
    src="${DF_SRC}"
    case "${src}" in
      *:*) : ;;   # host:/path 형태 → NFS 정상
      *)   warn "NFS가 아님 (${src}) — automount 실패 가능."
           warn "  복구: sudo mount -a 후 sudo docker compose -f ${COMPOSE_FILE} up -d --force-recreate ${team}" ;;
    esac
  fi
}

main(){
  command -v docker >/dev/null || { log "docker 명령을 찾을 수 없습니다."; exit 1; }

  # mapfile(bash4+)에 의존하지 않도록 while-read + 프로세스 치환으로 수집한다.
  # (< <(...) 이므로 루프가 현재 셸에서 돌아 targets/PROBLEMS 변경이 유지된다)
  local targets=() t c found
  if (($#)); then
    for t in "$@"; do
      found=0
      while IFS= read -r c; do
        [[ -n "${c}" ]] || continue
        targets+=("${c}")
        found=1
      done < <(list_team_containers | grep -E "^${t}_" || true)
      if ((found == 0)); then
        log "!! ${t}: 컨테이너를 찾을 수 없음"
        PROBLEMS=$((PROBLEMS+1))
      fi
    done
  else
    while IFS= read -r c; do
      [[ -n "${c}" ]] || continue
      targets+=("${c}")
    done < <(list_team_containers)
  fi

  if ((${#targets[@]} == 0)); then
    log "점검할 팀 컨테이너가 없습니다."
    exit 1
  fi

  for c in "${targets[@]}"; do
    check_one "${c}"
  done

  log ""
  log "════════════════════════════════════════"
  if ((PROBLEMS == 0)); then
    log "  이상 없음 — 팀 ${#targets[@]}개 정상"
  else
    log "  문제 ${PROBLEMS}건 발견 — 위의 '!!' 표시 확인"
  fi
  log "════════════════════════════════════════"
  ((PROBLEMS == 0))
}

main "$@"
