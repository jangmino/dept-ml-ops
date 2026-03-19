# 🔧 GPU 서버 팀 운영 가이드 — 관리자용

> VS Code + Remote-SSH + Team Container 환경
>
> 팀 생성, 키 등록, 컨테이너 관리, 로컬/NFS 쿼터 운영 등 관리 전반을 다룹니다.

---

## 인프라 구조

```
┌─────────────────────────────────────────────────┐
│  GPU 서버 (210.125.91.95)                        │
│  PRO 6000 × 4, NVMe 7TB                         │
│                                                 │
│  /data (XFS+prjquota) ─ 팀별 로컬 워크스페이스        │
│  /mnt/nfs/teams ─────── NFS 마운트 (스토리지)       │
│                                                 │
│  teamctl-xfs.sh ──SSH──→ nfsctl.sh (원격 호출)  │
│                                                 │
│  컨테이너 내부:                                  │
│    /workspace, /home/<team> → /data/teams/<team> │
│    /nfs/team → /mnt/nfs/teams/<team>             │
└──────────────────────┬──────────────────────────┘
                       │ NFSv4
┌──────────────────────▼──────────────────────────┐
│  스토리지 서버 (210.125.91.94)                   │
│  RAID-6, ~100TB                                  │
│                                                  │
│  /nfs (XFS+prjquota) ─ /nfs/teams/<team>         │
│  nfsctl.sh ─ 팀 폴더/쿼터 관리                   │
└──────────────────────────────────────────────────┘
```

### 관리 스크립트 요약

| 스크립트 | 위치 | 서버 | 역할 |
|----------|------|------|------|
| `teamctl-xfs.sh` | `/opt/mlops/` | GPU 서버 | 팀 생성, 컨테이너, 로컬 쿼터, NFS 원격 호출 통합 |
| `nfsctl.sh` | `/opt/nfs/` | 스토리지 서버 | NFS 팀 폴더/쿼터 관리 (teamctl에서 SSH로 호출됨) |

### UID/GID 규칙

`team = UID = GID = ProjectID` 규칙으로 운영합니다.

| 팀 | UID | GID | ProjectID | SSH 포트 |
|----|-----|-----|-----------|----------|
| team01 | 12001 | 12001 | 12001 | 22021 |
| team02 | 12002 | 12002 | 12002 | 22022 |
| teamNN | 12000+N | 12000+N | 12000+N | 22020+N |

---

## 1. 팀별 접속 정보 관리

### 접속 정보 표 템플릿

| TEAM | HOST | PORT | GPU | 로컬 QUOTA | NFS QUOTA | 비고 |
|------|------|------|-----|------------|-----------|------|
| team01 | `<서버IP>` | 22021 | 0 | 290G / 300G | 1950G / 2000G | 예시 |
| team02 | `<서버IP>` | 22022 | 1 | 290G / 300G | 1950G / 2000G | |

### 표 채우기 — 자동 생성

#### 방법 A) audit 결과 직접 확인

```bash
sudo /opt/mlops/teamctl-xfs.sh audit
```

#### 방법 B) Markdown 표로 변환 (복붙용)

```bash
sudo /opt/mlops/teamctl-xfs.sh audit | awk '
BEGIN {
  print "| TEAM | PORT | GPU | UID | GID | QUOTA(Soft/Hard) |";
  print "|------|------|-----|-----|-----|------------------|";
}
/^[a-zA-Z0-9._-]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+/ {
  team=$1; gpu=$2; port=$3; uid=$4; gid=$5;
  printf("| %s | %s | %s | %s | %s | %s |\n", team, port, gpu, uid, gid, "-");
}'
```

#### 방법 C) QUOTA 포함 (권장)

두 명령의 결과를 조합합니다.

```bash
# 1) 팀 구성 (포트/GPU/UID/GID)
sudo /opt/mlops/teamctl-xfs.sh audit

# 2) 로컬 XFS 쿼터
sudo xfs_quota -x -c 'report -p -n' /data

# 3) NFS 쿼터 (스토리지 서버에서 직접 또는 원격)
ssh -i /opt/mlops/keys/nfsctl_ed25519 nfsadmin@210.125.91.94 \
  "sudo /opt/nfs/nfsctl.sh quota"
```

---

## 2. 팀 생성 (로컬 + NFS 통합)

`--nfs` 플래그를 사용하면 로컬 워크스페이스와 NFS 스토리지를 한 번에 생성합니다.

```bash
sudo /opt/mlops/teamctl-xfs.sh create team01 \
  --gpu 0 \
  --image jangminnature/mlops:dept-20260208 \
  --size 300G --soft 290G \
  --nfs --nfs-size 2000G --nfs-soft 1950G
```

`--nfs` 없이 로컬만 생성할 수도 있습니다.

```bash
sudo /opt/mlops/teamctl-xfs.sh create team01 \
  --gpu 0 --image mlops:latest --size 300G --soft 290G
```

### 컨테이너 기동

```bash
sudo docker compose -f /opt/mlops/compose.yaml up -d team01
```

### 생성 결과 검증

```bash
sudo docker exec -it team01_gpu0 bash -lc '
echo "== mounts ==";
mount | egrep "/workspace|/home/team01|/nfs/team" || true;
echo;
echo "== df ==";
df -h /workspace /home/team01 /nfs/team || true;
su -s /bin/bash -c "id; ls -al /nfs/team | head" team01
'
```

---

## 3. 팀원 공개키 등록

### 키 문자열로 등록

```bash
sudo /opt/mlops/teamctl-xfs.sh add-key team01 --key "ssh-ed25519 AAAA... team01/jangmin"
```

### 등록 확인

```bash
sudo cat /data/ssh/team01/authorized_keys
```

### 권한 복구

```bash
sudo /opt/mlops/teamctl-xfs.sh fix-perms team01
```
- 필요시 [FAQ: fix-perms 설명 참고](#q-fix-perms-team-은-무엇을-하나요)
---

## 4. 쿼터 관리

로컬 쿼터와 NFS 쿼터는 **독립적으로** 관리됩니다.

### 로컬 쿼터 변경

```bash
sudo /opt/mlops/teamctl-xfs.sh resize team01 --size 500G --soft 490G
```

### NFS 쿼터 변경

```bash
sudo /opt/mlops/teamctl-xfs.sh nfs-resize team01 --nfs-size 3000G --nfs-soft 2950G
```

### 쿼터 현황 조회

```bash
# 로컬
sudo xfs_quota -x -c 'report -p -n' /data

# NFS (원격)
sudo ssh -i /opt/mlops/keys/nfsctl_ed25519 nfsadmin@210.125.91.94 \
  "sudo /opt/nfs/nfsctl.sh quota"
```

---

## 5. 컨테이너 상태 확인

```bash
cd /opt/mlops
sudo docker compose -f /opt/mlops/compose.yaml ps
sudo docker logs --tail 200 team01_gpu0
```

---

## 6. 새 이미지로 컨테이너 교체 (롤아웃)

```bash
# 1) 이미지 pull
sudo docker pull <image:tag>

# 2) compose 이미지 갱신
sudo /opt/mlops/teamctl-xfs.sh set-image team01 <image:tag>

# 3) 해당 팀만 재생성
sudo docker compose -f /opt/mlops/compose.yaml up -d --no-deps --force-recreate team01

# 4) 적용 확인
sudo docker inspect -f '{{.Config.Image}}' team01_gpu0
```

---

## 7. 팀 삭제

### 컨테이너만 중지 (데이터 보존)

```bash
sudo /opt/mlops/teamctl-xfs.sh reset team01
```

### 로컬 데이터까지 삭제

```bash
sudo /opt/mlops/teamctl-xfs.sh remove team01 --purge-data
```

### 로컬 + NFS 쿼터/매핑 삭제 (디렉터리 보존)

```bash
sudo /opt/mlops/teamctl-xfs.sh remove team01 --purge-data --purge-nfs
```

### 로컬 + NFS 전부 삭제 (디렉터리 포함)

```bash
sudo /opt/mlops/teamctl-xfs.sh remove team01 --purge-data --purge-nfs --purge-nfs-dir
```

> **주의:** compose.yaml에서 해당 팀 서비스 블록은 `remove` 시 자동 제거됩니다.

---

## 8. SSH host key 영구화 (권장)

컨테이너가 재생성되어도 팀원이 매번 `known_hosts` 경고를 겪지 않도록 합니다.

### 운영 원칙

- 팀별 host key 저장소: `/data/ssh/<team>/hostkeys`
- 컨테이너 마운트: `/etc/ssh/hostkeys`
- entrypoint에서 키가 없으면 생성, sshd가 해당 키를 사용

### 기존 팀 수동 적용

```bash
sudo mkdir -p /data/ssh/team01/hostkeys
sudo chown root:root /data/ssh/team01/hostkeys
sudo chmod 700 /data/ssh/team01/hostkeys
```

---

## 9. Compose 전체 내리기

```bash
cd /opt/mlops
sudo docker compose -f /opt/mlops/compose.yaml down
```

> 모니터링 스택은 `/opt/monitoring` 에서 별도로 down합니다.

---

## 10. 장애 체크리스트

### 컨테이너 재시작 루프

```bash
sudo docker ps
sudo docker logs --tail 200 team01_gpu0
```

### authorized_keys 권한/링크

```bash
sudo docker exec -it team01_gpu0 bash -lc \
  'ls -la /home/team01/.ssh && cat /home/team01/.ssh/authorized_keys'
```

### 로컬 quota 상태

```bash
sudo xfs_quota -x -c 'state' /data
sudo xfs_quota -x -c 'report -p -n' /data
```

### NFS 마운트 상태 (GPU 서버)

```bash
mountpoint /mnt/nfs/teams && echo "OK" || echo "NOT MOUNTED"
df -h /mnt/nfs/teams
```

### NFS 스토리지 서버 연결 테스트

```bash
sudo ssh -i /opt/mlops/keys/nfsctl_ed25519 \
  -o BatchMode=yes -o ConnectTimeout=5 \
  nfsadmin@210.125.91.94 "sudo /opt/nfs/nfsctl.sh audit"
```

### GPU 모니터링

```bash
# 호스트에서 전체 GPU 실시간 확인
watch -n 2 nvidia-smi

# 특정 컨테이너의 GPU 확인
docker exec <container_name> nvidia-smi
```

---

## 11. 일상 운영 체크리스트

### 일일 점검

- [ ] `nvidia-smi`로 전체 GPU 상태 확인 (호스트)
- [ ] `docker ps`로 각 컨테이너 정상 가동 확인
- [ ] 로컬 디스크 쿼터 초과 팀 유무 점검
- [ ] NFS 마운트 상태 확인: `mountpoint /mnt/nfs/teams`

### 주간 점검

- [ ] `teamctl-xfs.sh audit` 실행하여 팀 설정 무결성 확인
- [ ] 로컬 + NFS 쿼터 리포트 확인 및 이상 팀 알림
- [ ] 미사용 컨테이너 / 좀비 프로세스 정리
- [ ] 스토리지 서버 디스크 전체 사용률 확인

---

## 12. teamctl-xfs.sh 전체 명령 레퍼런스

```
sudo teamctl-xfs.sh set-gpu-mode 4|8
sudo teamctl-xfs.sh create TEAM --gpu N [--image IMG] [--size S] [--soft S]
                     [--nfs] [--nfs-size S] [--nfs-soft S]
sudo teamctl-xfs.sh add-key TEAM --key "ssh-ed25519 ..."
sudo teamctl-xfs.sh fix-perms TEAM
sudo teamctl-xfs.sh audit
sudo teamctl-xfs.sh list-mounts
sudo teamctl-xfs.sh backup-keys TEAM [--out DIR]
sudo teamctl-xfs.sh resize TEAM --size S [--soft S]           # 로컬만
sudo teamctl-xfs.sh nfs-resize TEAM --nfs-size S [--nfs-soft S]  # NFS만
sudo teamctl-xfs.sh reset TEAM
sudo teamctl-xfs.sh remove TEAM [--purge-data] [--purge-nfs] [--purge-nfs-dir]
sudo teamctl-xfs.sh set-image TEAM image:tag
```

---

## 13. FAQ

### Q. `fix-perms TEAM` 은 무엇을 하나요?

```bash
sudo /opt/mlops/teamctl-xfs.sh fix-perms team01
```

SSH 키 디렉토리의 소유자와 권한을 올바르게 복구합니다. 컨테이너 재생성이나 수동 작업 후 권한이 틀어졌을 때 사용합니다.

**대상 경로:** `/data/ssh/team01/`

| 대상 | 소유자 | 권한 | 의미 |
|------|--------|------|------|
| `/data/ssh/team01/` (디렉토리) | `root:12001` | `750` | 팀 그룹은 읽기+진입 가능, 외부는 접근 불가 |
| `/data/ssh/team01/authorized_keys` | `root:12001` | `640` | 팀 그룹은 읽기만 가능, 쓰기는 root만 |

**권한 값 해석:**

- `750` = 소유자(rwx) / 그룹(r-x) / 기타(---)
- `640` = 소유자(rw-) / 그룹(r--) / 기타(---)

**왜 이 권한이어야 하나?**
OpenSSH는 `authorized_keys`에 그룹/기타 쓰기 권한이 있으면 해당 키를 무시합니다. `640`은 sshd가 파일을 읽을 수 있으면서도 팀원이 직접 수정하지 못하도록 하는 최소 권한입니다.

**언제 사용하나?**
`audit` 결과에서 SSH 관련 이상이 표시되거나, `add-key` 후에도 SSH 접속이 안 될 때 실행합니다.
