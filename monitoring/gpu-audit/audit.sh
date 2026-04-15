#!/usr/bin/env bash
# gpu-audit.sh — 팀별 GPU 평균 사용률 감사 도구
#
# 배포 경로: /opt/mlops/gpu-audit.sh (gpu-new)
# 사용법: sudo /opt/mlops/gpu-audit.sh [--days N] [--threshold P] [--server NAME] [--format table|csv]
#
# Prometheus에 저장된 DCGM_FI_DEV_GPU_UTIL 메트릭을 최근 N일 평균으로 집계하여,
# 각 GPU 서버의 compose.yaml에서 추출한 (team, gpu) 매핑과 결합해 팀별 사용률을 리포트한다.

set -euo pipefail

# -------------------------
# Defaults
# -------------------------
DAYS=30
THRESHOLD=10
SERVER_FILTER=""
FORMAT="table"
PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
HOSTS_FILE="${HOSTS_FILE:-/opt/mlops/audit-hosts.tsv}"
EXEMPT_FILE="${EXEMPT_FILE:-/opt/mlops/gpu-audit-exempt.txt}"
LOCAL_COMPOSE="${LOCAL_COMPOSE:-/opt/mlops/compose.yaml}"
SSH_KEY="${SSH_KEY:-}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)

# -------------------------
# Helpers
# -------------------------
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "==> $*" >&2; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "required command missing: $1"; }

usage(){
  cat <<EOF
Usage: $0 [options]

Options:
  --days N              평균 산정 기간(일). 기본 ${DAYS}.
  --threshold P         저사용 판정 임계값(%). 기본 ${THRESHOLD}.
  --server NAME         특정 서버만 감사 (예: gpu-new). 기본: Prometheus에서 발견된 전체.
  --format table|csv    출력 형식. 기본 ${FORMAT}.
  --prom-url URL        Prometheus URL. 기본 ${PROM_URL}.
  --hosts-file PATH     서버별 SSH 대상 매핑 파일 (TSV: server<TAB>ssh_target). 없으면 로컬만 감사.
  --exempt-file PATH    감사 면제 팀 목록 (한 줄에 하나, # 주석 허용).
  --ssh-key PATH        SSH 개인키. 기본: ssh-agent / ~/.ssh/id_*.
  -h, --help            이 도움말.

Env overrides: PROM_URL, HOSTS_FILE, EXEMPT_FILE, LOCAL_COMPOSE, SSH_KEY

Examples:
  $0                                # 30일 평균, 10% 미만 경고
  $0 --days 14 --threshold 5        # 2주 평균, 5% 미만 강력 후보
  $0 --server gpu-new --format csv  # 신서버만 CSV 출력
EOF
}

# -------------------------
# Parse args
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)        DAYS="${2:-}"; shift 2;;
    --threshold)   THRESHOLD="${2:-}"; shift 2;;
    --server)      SERVER_FILTER="${2:-}"; shift 2;;
    --format)      FORMAT="${2:-}"; shift 2;;
    --prom-url)    PROM_URL="${2:-}"; shift 2;;
    --hosts-file)  HOSTS_FILE="${2:-}"; shift 2;;
    --exempt-file) EXEMPT_FILE="${2:-}"; shift 2;;
    --ssh-key)     SSH_KEY="${2:-}"; shift 2;;
    -h|--help)     usage; exit 0;;
    *)             die "unknown arg: $1 (see --help)";;
  esac
done

[[ "${DAYS}" =~ ^[0-9]+$ ]] || die "--days must be a positive integer"
[[ "${THRESHOLD}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--threshold must be numeric"
[[ "${FORMAT}" == "table" || "${FORMAT}" == "csv" ]] || die "--format must be 'table' or 'csv'"

need_cmd curl
need_cmd jq
need_cmd awk

[[ -n "${SSH_KEY}" ]] && SSH_OPTS+=(-i "${SSH_KEY}")

# -------------------------
# Prometheus helpers
# -------------------------
prom_query(){
  local q="$1"
  curl -fsSG --data-urlencode "query=${q}" "${PROM_URL}/api/v1/query" \
    || die "Prometheus query failed: ${q}"
}

prom_label_values(){
  local label="$1"
  curl -fsS "${PROM_URL}/api/v1/label/${label}/values" \
    | jq -r '.data[]? // empty'
}

# -------------------------
# Discover servers
# -------------------------
discover_servers(){
  # Prometheus에 server 라벨이 설정되어 있으면 그 목록 사용.
  # 없으면 단일 서버 모드로 "local" 플레이스홀더 반환.
  local vals
  vals="$(prom_label_values server 2>/dev/null || true)"
  if [[ -n "${vals}" ]]; then
    echo "${vals}"
  else
    echo "local"
  fi
}

# -------------------------
# Team ↔ GPU mapping
# -------------------------
# compose.yaml에서 container_name: teamXX_gpuN 패턴과 device_ids 블록을 읽어
# "team<TAB>gpu_id" 를 출력.
extract_mapping_from_compose(){
  awk '
    /^  [a-zA-Z0-9_]+:$/ {
      svc=$1; sub(/:$/, "", svc); team=""; gpu=""
    }
    /container_name:[[:space:]]*[a-zA-Z0-9_]+_gpu[0-9]+/ {
      match($0, /container_name:[[:space:]]*([a-zA-Z0-9_]+)_gpu([0-9]+)/, m)
      team=m[1]; gpu=m[2]
      if (team != "" && gpu != "") { print team "\t" gpu }
    }
  '
}

fetch_mapping(){
  local server="$1"
  local ssh_target=""

  if [[ "${server}" == "local" ]]; then
    [[ -r "${LOCAL_COMPOSE}" ]] || die "local compose not readable: ${LOCAL_COMPOSE}"
    extract_mapping_from_compose < "${LOCAL_COMPOSE}"
    return
  fi

  if [[ -r "${HOSTS_FILE}" ]]; then
    ssh_target="$(awk -v s="${server}" '$1==s{print $2; exit}' "${HOSTS_FILE}")"
  fi

  if [[ -z "${ssh_target}" ]]; then
    # hosts 파일에 엔트리 없음 → 로컬로 가정 (단일 서버 배포)
    if [[ -r "${LOCAL_COMPOSE}" ]]; then
      extract_mapping_from_compose < "${LOCAL_COMPOSE}"
      return
    fi
    log "WARNING: no ssh target for '${server}' and no local compose; skipping"
    return
  fi

  ssh "${SSH_OPTS[@]}" "${ssh_target}" "cat ${LOCAL_COMPOSE}" \
    | extract_mapping_from_compose \
    || { log "WARNING: failed to fetch compose from ${ssh_target}"; return; }
}

# -------------------------
# Exempt list
# -------------------------
is_exempt(){
  local team="$1"
  [[ -r "${EXEMPT_FILE}" ]] || return 1
  awk -v t="${team}" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { gsub(/^[[:space:]]+|[[:space:]]+$/,""); if ($0==t) { found=1; exit } }
    END { exit(found?0:1) }
  ' "${EXEMPT_FILE}"
}

# -------------------------
# Query GPU utilization
# -------------------------
# 결과: "server<TAB>gpu<TAB>avg_util" (한 줄씩)
query_gpu_utilization(){
  local days="$1" server="$2"
  local q
  if [[ "${server}" == "local" ]]; then
    q="avg_over_time(DCGM_FI_DEV_GPU_UTIL[${days}d])"
  else
    q="avg_over_time(DCGM_FI_DEV_GPU_UTIL{server=\"${server}\"}[${days}d])"
  fi

  prom_query "${q}" | jq -r --arg srv "${server}" '
    .data.result[]? |
    [ (.metric.server // $srv),
      (.metric.gpu   // "?"),
      (.value[1]     // "0") ]
    | @tsv
  '
}

# -------------------------
# Main
# -------------------------
main(){
  local servers
  if [[ -n "${SERVER_FILTER}" ]]; then
    servers="${SERVER_FILTER}"
  else
    servers="$(discover_servers)"
  fi
  [[ -n "${servers}" ]] || die "no servers to audit"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT

  local map_file="${tmp}/mapping.tsv"
  local util_file="${tmp}/util.tsv"
  : > "${map_file}"
  : > "${util_file}"

  log "Auditing servers: $(echo "${servers}" | tr '\n' ' ')"

  local s
  for s in ${servers}; do
    log "  - collecting mapping from ${s}"
    fetch_mapping "${s}" | awk -v srv="${s}" 'NF==2 { print srv "\t" $1 "\t" $2 }' >> "${map_file}" || true

    log "  - querying utilization for ${s} (avg over ${DAYS}d)"
    query_gpu_utilization "${DAYS}" "${s}" >> "${util_file}" || true
  done

  # 조인: (server, gpu) 기준으로 매핑과 사용률 결합 → (server, team, gpu, util)
  local joined="${tmp}/joined.tsv"
  awk -F'\t' '
    NR==FNR { u[$1"|"$2]=$3; next }          # util_file: server<TAB>gpu<TAB>util
    {
      key=$1"|"$3                              # map: server<TAB>team<TAB>gpu
      util=(key in u) ? u[key] : "NaN"
      print $1 "\t" $2 "\t" $3 "\t" util
    }
  ' "${util_file}" "${map_file}" > "${joined}"

  # 팀 단위 집계 (여러 GPU일 경우 평균)
  local aggregated="${tmp}/agg.tsv"
  awk -F'\t' '
    {
      key=$1"|"$2
      if ($4 != "NaN") { sum[key]+=$4; cnt[key]++ }
      gpus[key] = (key in gpus ? gpus[key]"," : "") $3
      srv[key]=$1; team[key]=$2
    }
    END {
      for (k in srv) {
        avg = (cnt[k]>0) ? sum[k]/cnt[k] : -1
        printf "%s\t%s\t%s\t%.2f\n", srv[k], team[k], gpus[k], avg
      }
    }
  ' "${joined}" | sort -t$'\t' -k1,1 -k2,2 > "${aggregated}"

  # 출력
  if [[ "${FORMAT}" == "csv" ]]; then
    echo "server,team,gpus,avg_util_pct,status"
    awk -F'\t' -v th="${THRESHOLD}" -v ex="${EXEMPT_FILE}" '
      BEGIN {
        while ((getline line < ex) > 0) {
          sub(/#.*$/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/,"",line)
          if (line != "") exempt[line]=1
        }
      }
      {
        status = ($4 < 0) ? "NO_DATA" : ($4 < th ? "LOW" : "OK")
        if (status=="LOW" && ($2 in exempt)) status="LOW_EXEMPT"
        printf "%s,%s,%s,%.2f,%s\n", $1, $2, $3, $4, status
      }
    ' "${aggregated}"
  else
    printf "%-10s %-10s %-14s %12s   %s\n" "SERVER" "TEAM" "GPUs" "AVG_UTIL" "STATUS"
    printf "%-10s %-10s %-14s %12s   %s\n" "------" "----" "----" "--------" "------"
    awk -F'\t' -v th="${THRESHOLD}" -v ex="${EXEMPT_FILE}" '
      BEGIN {
        while ((getline line < ex) > 0) {
          sub(/#.*$/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/,"",line)
          if (line != "") exempt[line]=1
        }
      }
      {
        if ($4 < 0)        { status="NO_DATA"; pct="   n/a" }
        else if ($4 < th)  { status=($2 in exempt ? "LOW (exempt)" : "LOW"); pct=sprintf("%6.2f%%", $4) }
        else               { status="OK"; pct=sprintf("%6.2f%%", $4) }
        printf "%-10s %-10s %-14s %12s   %s\n", $1, $2, $3, pct, status
      }
    ' "${aggregated}"
    echo
    echo "기간: 최근 ${DAYS}일 / 임계값: ${THRESHOLD}% / 생성: $(date '+%Y-%m-%d %H:%M:%S')"
  fi
}

main "$@"
