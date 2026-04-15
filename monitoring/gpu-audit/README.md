# GPU 사용률 감사 도구

팀별 GPU 평균 사용률을 Prometheus/DCGM 데이터에서 산출하여 저사용 팀을 식별하는 관리자용 스크립트.

## 배포

`gpu-new` 서버에 설치한다 (Prometheus가 있는 중앙 서버).

```bash
# 원본 저장소에서 복사
sudo install -m 0755 monitoring/gpu-audit/audit.sh /opt/mlops/gpu-audit.sh

# (선택) 감사 면제 팀 목록
sudo install -m 0644 /dev/null /opt/mlops/gpu-audit-exempt.txt

# (선택) 멀티서버 SSH 매핑 — 구서버 편입 시 사용
sudo tee /opt/mlops/audit-hosts.tsv >/dev/null <<'EOF'
# server_label    ssh_target
gpu-old1         root@210.125.91.xx
gpu-old2         root@210.125.91.xx
gpu-old3         root@210.125.91.xx
gpu-old4         root@210.125.91.xx
EOF
```

`gpu-new` 자신은 hosts 파일에 없어도 로컬 compose.yaml(`/opt/mlops/compose.yaml`)에서 직접 매핑을 읽는다.

## 의존성

- `curl`, `jq`, `awk`, `ssh` (멀티서버 시)
- Prometheus는 localhost:9090에서 접근 가능해야 함 (`PROM_URL` 환경변수로 override 가능)

## 사용법

```bash
sudo /opt/mlops/gpu-audit.sh [--days N] [--threshold P] [--server NAME] [--format table|csv]
```

**주요 옵션**:

| 옵션 | 기본값 | 설명 |
|------|-------|------|
| `--days` | 30 | 평균 산정 기간(일) |
| `--threshold` | 10 | 저사용 판정 임계값(%) |
| `--server` | (전체) | 특정 서버만 (예: gpu-new) |
| `--format` | table | `table` 또는 `csv` |
| `--prom-url` | http://127.0.0.1:9090 | Prometheus URL |
| `--hosts-file` | /opt/mlops/audit-hosts.tsv | 서버별 SSH 대상 매핑 |
| `--exempt-file` | /opt/mlops/gpu-audit-exempt.txt | 면제 팀 목록 |
| `--ssh-key` | (없음) | SSH 개인키 경로 |

Prometheus 보관 기간은 45일이므로 `--days`는 45 이하로 지정한다.

## 예시

```bash
# 최근 30일 평균 10% 미만 경고 (표준 감사)
sudo /opt/mlops/gpu-audit.sh

# 짧은 구간 드라이런
sudo /opt/mlops/gpu-audit.sh --days 1

# 강력 회수 후보만 (최근 2주 평균 5% 미만)
sudo /opt/mlops/gpu-audit.sh --days 14 --threshold 5

# 신서버만 CSV로 출력 (파이프/엑셀 가공용)
sudo /opt/mlops/gpu-audit.sh --server gpu-new --format csv > /tmp/audit.csv
```

## 출력 예시

```
SERVER     TEAM       GPUs              AVG_UTIL   STATUS
------     ----       ----              --------   ------
gpu-new    team01     0                  42.10%   OK
gpu-new    team02     1                   3.82%   LOW
gpu-new    team03     2                   0.15%   LOW (exempt)
gpu-new    team04     3                      n/a  NO_DATA

기간: 최근 30일 / 임계값: 10% / 생성: 2026-04-15 14:02:31
```

- `OK`: 임계값 이상 사용 중
- `LOW`: 저사용 후보
- `LOW (exempt)`: 저사용이지만 면제 목록에 포함됨 (수업용/연구실 등)
- `NO_DATA`: 메트릭 부재 (컨테이너가 최근 생성되었거나 DCGM 수집 실패)

## 동작 원리

1. **서버 목록 결정** — `SERVER_FILTER` 없으면 `label_values(up, server)` 쿼리로 Prometheus가 알고 있는 서버 전체 조회. `server` 라벨이 없으면(단일 서버 모드) 로컬만 감사.
2. **팀 ↔ GPU 매핑 수집** — 각 서버의 `/opt/mlops/compose.yaml`에서 `container_name: {team}_gpu{N}` 패턴을 awk로 추출.
3. **사용률 쿼리** — `avg_over_time(DCGM_FI_DEV_GPU_UTIL{server="$S"}[${DAYS}d])` Prometheus API 호출.
4. **조인·집계** — (server, gpu) 키로 매핑과 사용률을 결합, 팀당 평균 산출.
5. **판정** — 임계값 미만은 LOW, 면제 목록에 있으면 `LOW (exempt)`.

## 면제 목록 (exempt)

`/opt/mlops/gpu-audit-exempt.txt` — 한 줄에 팀 하나, `#` 주석 지원.

```
# 학부 수업용 (정상적으로 저사용)
team07
# 연구실 공용 (주기적 배치만)
team11
```

## 구서버 편입 시

1. `audit-hosts.tsv`에 `gpu-old1..4` 엔트리 추가
2. gpu-new → 구서버 SSH 키가 배포되어 있어야 함
3. 각 구서버에 동일 버전 `compose.yaml`과 `teamctl-xfs.sh`가 설치되어 있어야 함
4. `prometheus.yml`의 scrape 대상에 구서버 DCGM exporter 추가되면 자동으로 감사 대상에 포함됨

스크립트 코드는 수정할 필요 없다.

## 감사/회수 워크플로

관리자 운영 가이드는 [../../manual/README-admin.md](../../manual/README-admin.md)의 "GPU 사용률 감사 및 회수" 섹션 참고.
