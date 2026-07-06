#!/usr/bin/env bash
#
# teams-provision.sh — 팀 일괄 생성/키등록 (매니페스트 = 키 디렉터리)
#
# 매니페스트는 "키 디렉터리"다. 각 서버에서, 그 서버가 담당하는 팀의
# 공개키를 teamkeys/<team>.pub 로 준비한 뒤 실행한다.
#   미리보기(실행 안 함):  DRYRUN=1 ./teams-provision.sh ./teamkeys
#   실제 실행:            ./teams-provision.sh ./teamkeys
#
# 서버 프로파일은 팀 번호의 "십의 자리"로 자동 선택된다 (번호 체계와 동일):
#   team0x -> gpu-new (GPU 4장, GPU 0~3, local 300/290G, NFS 2000/1950G)
#   team1x -> gpu-old1  ┐
#   team2x -> gpu-old2  ├ (GPU 8장, GPU 0~7, local 90/85G, NFS 1800/1750G)
#   team3x -> gpu-old3  │
#   team4x -> gpu-old4  ┘
#   - GPU 인덱스 = 팀번호 끝자리 - 1 (team01->0, team11->0 ... team18->7)
#   - 프로파일의 GPU 개수를 넘는 팀은 건너뜀 (gpu-new에서 team05+ 자동 거부)
#
# 규칙:
#   - 이미 compose에 있는 팀은 create 건너뜀(멱등). add-key도 중복이면 skip.
#   - <team>.pub 에 공개키 여러 줄 가능(한 줄당 키 하나). '#' 주석/빈 줄 무시.
#   - 실패 시 중단(set -e). 고친 뒤 재실행하면 완료된 팀은 건너뛰므로 안전.
#
# ⚠️ 이 서버가 담당하는 팀만 teamkeys/에 두세요. (gpu-new=team0x, old1=team1x ...)
#    프로파일은 팀번호로 자동 선택되지만, 다른 서버 팀을 여기서 만들면
#    GPU 인덱스는 물리 장치 기준이라 UID/포트가 원래 서버와 충돌합니다.
#    실행 전 DRYRUN=1로 각 팀의 프로파일/GPU가 맞는지 반드시 확인하세요.
#
set -euo pipefail

TEAMCTL="/opt/mlops/teamctl-xfs.sh"
COMPOSE="/opt/mlops/compose.yaml"
# 이미지 태그는 전 서버 공용(env로 override 가능). 배포 전 최신 태그인지 확인.
IMAGE="${IMAGE:-jangminnature/mlops:dept-20260208}"

KEYDIR="${1:-./teamkeys}"
DRYRUN="${DRYRUN:-0}"

say(){ printf '%s\n' "$*"; }
run(){ say "  + $*"; [[ "${DRYRUN}" == "1" ]] || sudo "$@"; }

# 팀 번호 십의 자리 -> 서버 프로파일. 전역에 프로파일 값을 세팅한다.
#   설정: P_SRV P_MAXGPU P_LOC_H P_LOC_S P_NFS_H P_NFS_S  (실패 시 1)
select_profile(){
  local tens="$1"
  case "${tens}" in
    0) P_SRV="gpu-new";        P_MAXGPU=4; P_LOC_H="300G"; P_LOC_S="290G"; P_NFS_H="2000G"; P_NFS_S="1950G" ;;
    1|2|3|4) P_SRV="gpu-old${tens}"; P_MAXGPU=8; P_LOC_H="90G";  P_LOC_S="85G";  P_NFS_H="1800G"; P_NFS_S="1750G" ;;
    *) return 1 ;;
  esac
  return 0
}

shopt -s nullglob
files=( "${KEYDIR}"/team*.pub )
(( ${#files[@]} )) || { say "키 파일이 없음: ${KEYDIR}/team*.pub"; exit 1; }

say "=== teams-provision (DRYRUN=${DRYRUN}) — ${#files[@]}개 팀 / image=${IMAGE} ==="
for kf in "${files[@]}"; do
  team="$(basename "${kf}" .pub)"
  [[ "${team}" =~ ^team[0-9]+$ ]] || { say "!! 팀명 형식 아님, 건너뜀: ${team}"; continue; }

  num="${team#team}"                 # "01", "18"
  tens=$(( 10#${num} / 10 ))         # 0 = gpu-new, 1~4 = old1~4
  ones=$(( 10#${num} % 10 ))         # 끝자리
  gpu=$(( ones - 1 ))                # GPU 인덱스

  if ! select_profile "${tens}"; then
    say ""; say "!! ${team}: 서버 프로파일 없음(십의 자리=${tens}, 유효 0~4). 건너뜀"; continue
  fi

  say ""
  say "=== ${team}  ->  ${P_SRV}  (GPU ${gpu} / local ${P_LOC_H}·${P_LOC_S}, NFS ${P_NFS_H}·${P_NFS_S}) ==="

  if (( gpu < 0 || gpu >= P_MAXGPU )); then
    say "  !! GPU 인덱스 ${gpu} 가 ${P_SRV}(GPU ${P_MAXGPU}장) 범위 밖 → 건너뜀 (끝자리는 1~${P_MAXGPU}이어야 함)"
    continue
  fi

  if grep -qE "^  ${team}:" "${COMPOSE}" 2>/dev/null; then
    say "  이미 compose에 존재 — create 건너뜀 (쿼터 변경은 resize/nfs-resize 사용)"
  else
    run "${TEAMCTL}" create "${team}" --gpu "${gpu}" --image "${IMAGE}" \
      --size "${P_LOC_H}" --soft "${P_LOC_S}" \
      --nfs --nfs-size "${P_NFS_H}" --nfs-soft "${P_NFS_S}"
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
