#!/usr/bin/env bash
#
# teams-provision.sh — 팀 일괄 생성/키등록 (매니페스트 = 키 디렉터리)
#
# 매니페스트는 "키 디렉터리"다. 각 서버에서, 그 서버가 담당하는 팀의
# 공개키를 teamkeys/<team>.pub 로 준비한 뒤 실행한다.
#   미리보기(실행 안 함):  DRYRUN=1 ./teams-provision.sh ./teamkeys
#   실제 실행:            ./teams-provision.sh ./teamkeys
#
# 규칙:
#   - 팀당 GPU 1개, 인덱스 = 팀번호 끝자리 - 1  (team11->0 ... team18->7)
#   - 로컬 90G/85G, NFS 1800G/1750G 쿼터 (아래 상수로 조정)
#   - 이미 compose에 있는 팀은 create 건너뜀(멱등). add-key도 중복이면 skip.
#   - <team>.pub 에 공개키 여러 줄 가능(한 줄당 키 하나). '#' 주석/빈 줄 무시.
#   - 실패 시 중단(set -e). 고친 뒤 재실행하면 완료된 팀은 건너뛰므로 안전.
#
# ⚠️ 이 서버가 담당하는 팀만 teamkeys/에 두세요. (old1=team1x, old2=team2x ...)
#    번호 체계를 어기면 UID/포트가 다른 서버와 충돌합니다.
#
set -euo pipefail

TEAMCTL="/opt/mlops/teamctl-xfs.sh"
COMPOSE="/opt/mlops/compose.yaml"
IMAGE="jangminnature/mlops:dept-20260208"
LOCAL_SIZE="90G";  LOCAL_SOFT="85G"
NFS_SIZE="1800G";  NFS_SOFT="1750G"

KEYDIR="${1:-./teamkeys}"
DRYRUN="${DRYRUN:-0}"

say(){ printf '%s\n' "$*"; }
run(){ say "  + $*"; [[ "${DRYRUN}" == "1" ]] || sudo "$@"; }

shopt -s nullglob
files=( "${KEYDIR}"/team*.pub )
(( ${#files[@]} )) || { say "키 파일이 없음: ${KEYDIR}/team*.pub"; exit 1; }

say "=== teams-provision (DRYRUN=${DRYRUN}) — ${#files[@]}개 팀 ==="
for kf in "${files[@]}"; do
  team="$(basename "${kf}" .pub)"
  [[ "${team}" =~ ^team[0-9]+$ ]] || { say "!! 팀명 형식 아님, 건너뜀: ${team}"; continue; }
  last="${team: -1}"
  gpu=$(( 10#${last} - 1 ))
  (( gpu >= 0 && gpu <= 7 )) || { say "!! ${team}: GPU 인덱스(${gpu}) 범위 밖(0~7). 끝자리는 1~8이어야 함. 건너뜀"; continue; }

  say ""
  say "=== ${team}  (GPU ${gpu}) ==="
  if grep -qE "^  ${team}:" "${COMPOSE}" 2>/dev/null; then
    say "  이미 compose에 존재 — create 건너뜀 (쿼터 변경은 resize/nfs-resize 사용)"
  else
    run "${TEAMCTL}" create "${team}" --gpu "${gpu}" --image "${IMAGE}" \
      --size "${LOCAL_SIZE}" --soft "${LOCAL_SOFT}" \
      --nfs --nfs-size "${NFS_SIZE}" --nfs-soft "${NFS_SOFT}"
  fi

  # 공개키 등록 (add-key는 중복이면 skip → 멱등)
  while IFS= read -r key || [[ -n "${key}" ]]; do
    key="${key%%$'\r'}"                       # CRLF 방어
    [[ -n "${key}" && "${key}" != \#* ]] || continue
    run "${TEAMCTL}" add-key "${team}" --key "${key}"
  done < "${kf}"

  # 컨테이너 기동
  run docker compose -f "${COMPOSE}" up -d "${team}"
done

say ""
say "완료. 검증:  sudo ${TEAMCTL} audit"
