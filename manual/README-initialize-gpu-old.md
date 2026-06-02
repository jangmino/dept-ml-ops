# 구 GPU 서버 초기화 매뉴얼

> 기존 GPU 서버 (8GPU) 기준
>
> OS를 재설치하고 파티션을 분리하여, 신규 서버와 동일한 teamctl-xfs.sh 기반 팀 컨테이너 환경을 구축합니다.
> 스토리지 서버([README-initialize-storage.md](README-initialize-storage.md))가 이미 운영 중이어야 합니다.

---

## 사전 준비

### Ubuntu 버전

신규 서버(gpu-new)와 동일한 **Ubuntu 24.04 LTS (Noble)** 를 설치합니다.

### 팀 번호 체계

십의 자리로 서버를 구분합니다. 모든 서버에서 팀 번호가 겹치지 않아야 NFS 권한이 정상 동작합니다.

| 서버 | 팀 범위 | UID/GID 범위 | SSH 포트 범위 | GPU 모드 |
|------|---------|-------------|-------------|----------|
| gpu-new | team01-team09 | 12001-12009 | 22021-22029 | 4 |
| gpu-old1 | team11-team19 | 12011-12019 | 22031-22039 | 8 |
| gpu-old2 | team21-team29 | 12021-12029 | 22041-22049 | 8 |
| gpu-old3 | team31-team39 | 12031-12039 | 22051-22059 | 8 |
| gpu-old4 | team41-team49 | 12041-12049 | 22061-22069 | 8 |

### 기존 데이터 안내

기존 사용자에게 필요한 데이터를 백업하도록 사전 안내합니다 (유예 기간 부여). OS 재설치 시 디스크 전체가 초기화됩니다.

---

## 1. OS 재설치 + 파티션 분리

### 1.1 기존 구조 (문제)

구 서버는 단일 파티션(`/dev/sda2`)에 OS와 사용자 데이터가 혼재되어 있습니다.

```
/dev/sda1  vfat   487MB  /boot/efi
/dev/sda2  ext4   879GB  /           ← OS + 사용자 데이터 혼재
```

### 1.2 목표 구조

OS 영역과 데이터 영역을 분리하여 `/data`를 XFS+prjquota로 운영합니다.

```
/dev/sda1  vfat   ~500MB  /boot/efi
/dev/sda2  ext4   ~100GB  /           (OS 영역)
/dev/sda3  XFS    나머지   /data       (팀 데이터, prjquota)
```

### 1.3 Ubuntu 설치 시 파티션 설정

Ubuntu 설치 USB로 부팅 후 **"Something else" (수동 파티셔닝)** 을 선택합니다.

| 파티션 | 크기 | 타입 | 마운트 | 포맷 |
|--------|------|------|--------|------|
| `/dev/sda1` | 512MB | EFI System Partition | `/boot/efi` | FAT32 |
| `/dev/sda2` | 100GB | ext4 | `/` | ext4 |
| `/dev/sda3` | 나머지 전체 | — | *설치 시 마운트하지 않음* | — |

> **중요:** `/dev/sda3`는 설치 과정에서 포맷하지 않습니다. 설치 완료 후 수동으로 XFS 포맷합니다.

### 1.4 설치 완료 후 — /data 파티션 XFS 포맷

```bash
# 파티션이 없으면 생성
sudo parted /dev/sda --script mkpart primary 100GiB 100%
sudo parted /dev/sda --script name 3 team-volumes
```

XFS 포맷:

```bash
sudo mkfs.xfs -f /dev/sda3
```

### 1.5 /data 마운트 + fstab 등록

```bash
sudo mkdir -p /data
sudo mount /dev/sda3 /data
```

UUID 확인:

```bash
sudo blkid /dev/sda3
```

`/etc/fstab`에 추가:

```
UUID=<위에서 확인한 UUID>  /data  xfs  defaults,noatime,prjquota  0  0
```

적용 + 확인:

```bash
sudo mount -a
df -hT /data    # xfs 확인
```

### 1.6 디렉터리 생성

```bash
sudo mkdir -p /data/teams /data/ssh /data/ssh_backups
```

---

## 2. 네트워크 설정

신규 서버 매뉴얼([README-initialize-gpu.md](README-initialize-gpu.md) 2절)을 참고하여 고정 IP를 설정합니다.

```yaml
# /etc/netplan/50-cloud-init.yaml (예시)
network:
    ethernets:
        eth0:
            dhcp4: no
            addresses:
              - 210.125.91.xx/24
            routes:
              - to: default
                via: 210.125.91.1
            nameservers:
              addresses: [210.125.88.1, 8.8.8.8]
    version: 2
```

```bash
sudo netplan apply
```

---

## 3. NVIDIA 드라이버 + Docker 설치

### 3.1 NVIDIA 드라이버

```bash
sudo apt update
sudo apt install -y nvidia-driver-570   # 신규 서버와 동일 버전으로 (확인 후 조정)
sudo reboot

# 재부팅 후 확인
nvidia-smi
```

> **참고:** 드라이버 버전은 신규 서버에서 `nvidia-smi`로 확인 후 맞춥니다.

### 3.2 Docker + NVIDIA Container Toolkit

```bash
# Docker 설치
curl -fsSL https://get.docker.com | sh
sudo systemctl enable --now docker

# NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# 확인
sudo docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

---

## 4. teamctl-xfs.sh 배포

```bash
cd ~/work && git clone https://github.com/jangmino/dept-ml-ops

sudo mkdir -p /opt/mlops
sudo cp ~/work/dept-ml-ops/gpu-servers/Dockerfile /opt/mlops/
sudo cp ~/work/dept-ml-ops/gpu-servers/docker-entrypoint.sh /opt/mlops/
sudo cp ~/work/dept-ml-ops/gpu-servers/teamctl-xfs.sh /opt/mlops/
sudo chmod +x /opt/mlops/teamctl-xfs.sh

# compose.yaml 스켈레톤 생성
echo "services:" | sudo tee /opt/mlops/compose.yaml
```

---

## 5. GPU 모드 설정

```bash
sudo /opt/mlops/teamctl-xfs.sh set-gpu-mode 8
```

---

## 6. Docker 이미지 준비

```bash
# Docker Hub에서 pull (빌드 완료된 이미지)
sudo docker pull jangminnature/mlops:dept-20260208

# 또는 로컬 빌드
cd /opt/mlops
sudo docker build -t jangminnature/mlops:dept-20260208 .
```

---

## 7. Bastion 초기 설정 (SSH 게이트웨이)

외부 SSH 접근을 22번 단일 포트로 모으는 bastion 구조를 활성화합니다. 본 서버에 1회만 실행하면 됩니다.

```bash
sudo /opt/mlops/teamctl-xfs.sh bastion-init
```

수행 내용:
- `jump` 시스템 계정 (셸: `/usr/sbin/nologin`)
- `/home/jump/.ssh/authorized_keys` 준비 (권한 600)
- `/etc/ssh/sshd_config.d/jump.conf` 작성 (`Match User jump`: `ForceCommand=/usr/sbin/nologin`, `AllowTcpForwarding=yes`, `PermitTTY=no`, X11/Agent/Tunnel 차단)
- `systemctl reload ssh`

이후 `add-key`/`remove` 명령이 자동으로 bastion authorized_keys를 동기화합니다. 자세한 운영·트러블슈팅은 [README-admin.md §14 Bastion 운영](README-admin.md) 참고.

### 외부 방화벽 규칙

| 포트 | 허용 | 비고 |
|------|-----|------|
| `22/tcp` | ✅ | bastion 진입 |
| `22031~22069/tcp` (구서버 범위) | ❌ | 컨테이너 SSH (외부 차단) |

```bash
sudo ufw allow 22/tcp
sudo ufw deny  22031:22069/tcp
```

(구서버는 모니터링 80번 노출 불필요 — Grafana는 gpu-new에만)

---

## 8. NFS 스토리지 연결

### 8.1 NFS 클라이언트 설치

```bash
sudo apt update
sudo apt install -y nfs-common
```

### 8.2 마운트 포인트 생성 + 마운트

```bash
sudo mkdir -p /mnt/nfs/teams
sudo mount -t nfs4 210.125.91.94:/teams /mnt/nfs/teams
df -h /mnt/nfs/teams
```

### 8.3 fstab 영구 마운트

부팅 시 네트워크 대기 설정:

```bash
sudo systemctl unmask systemd-networkd-wait-online.service
sudo systemctl enable systemd-networkd-wait-online.service
```

`/etc/fstab`에 추가:

```
210.125.91.94:/teams  /mnt/nfs/teams  nfs4  nfsvers=4.2,_netdev,hard,intr,timeo=600,retrans=2,x-systemd.automount,x-systemd.mount-timeout=60  0  0
```

적용:

```bash
sudo systemctl daemon-reload
sudo mount -a
```

### 8.4 NFS 원격 제어용 SSH 키 설정

**옵션 A — 신규 서버와 같은 키 공유 (간단):**

신규 서버에서 `/opt/mlops/keys/nfsctl_ed25519`를 복사합니다.

```bash
sudo mkdir -p /opt/mlops/keys
# (신규 서버에서 scp로 복사)
sudo chmod 600 /opt/mlops/keys/nfsctl_ed25519
```

**옵션 B — 서버별 별도 키 생성 (보안 우선):**

```bash
sudo mkdir -p /opt/mlops/keys
sudo ssh-keygen -t ed25519 -C "teamctl->nfsctl (gpu-oldN)" -f /opt/mlops/keys/nfsctl_ed25519
sudo chmod 600 /opt/mlops/keys/nfsctl_ed25519

# 공개키를 스토리지 서버 nfsadmin에 등록
sudo cat /opt/mlops/keys/nfsctl_ed25519.pub
# → 스토리지 서버의 /home/nfsadmin/.ssh/authorized_keys에 추가
```

### 8.5 연결 테스트

```bash
ssh -i /opt/mlops/keys/nfsctl_ed25519 \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  nfsadmin@210.125.91.94 "sudo /opt/nfs/nfsctl.sh audit"
```

---

## 9. 모니터링 exporter 배포

중앙 Prometheus(gpu-new)가 이 서버의 메트릭을 원격 scrape 합니다.

### 9.1 exporter 스택 배포

```bash
sudo mkdir -p /opt/monitoring
sudo cp ~/work/dept-ml-ops/monitoring/exporters/docker-compose.yaml /opt/monitoring/
```

### 9.2 .env 파일 생성

```bash
echo "SERVER_IP=<이 서버의 IP>" | sudo tee /opt/monitoring/.env
```

### 9.3 exporter 기동

```bash
cd /opt/monitoring
sudo docker compose up -d
sudo docker compose ps
```

### 9.4 방화벽 설정 — Prometheus 서버만 접근 허용

```bash
sudo ufw allow from 210.125.91.95 to any port 9100
sudo ufw allow from 210.125.91.95 to any port 8080
sudo ufw allow from 210.125.91.95 to any port 9400
```

### 9.5 중앙 Prometheus에 등록

gpu-new 서버에서 `prometheus.yml`의 해당 서버 주석을 해제하고 IP를 입력한 뒤:

```bash
cd /opt/monitoring
sudo docker compose restart prometheus
```

---

## 10. 팀 생성 및 컨테이너 기동

### 10.1 팀 생성 (예: gpu-old1의 team11)

```bash
sudo /opt/mlops/teamctl-xfs.sh create team11 \
  --gpu 0 \
  --image jangminnature/mlops:dept-20260208 \
  --size 300G --soft 290G \
  --nfs --nfs-size 2000G --nfs-soft 1950G
```

### 10.2 컨테이너 기동

```bash
sudo docker compose -f /opt/mlops/compose.yaml up -d team11
```

### 10.3 검증

```bash
sudo /opt/mlops/teamctl-xfs.sh audit
sudo xfs_quota -x -c "report -p -n" /data
```

---

## 전체 초기화 체크리스트

- [ ] 기존 사용자에게 데이터 백업 안내 (유예 기간)
- [ ] Ubuntu 재설치 (신규 서버와 동일 버전)
- [ ] 파티션 분리: `/dev/sda2`(ext4, ~100GB, OS) + `/dev/sda3`(XFS, 나머지, /data)
- [ ] `/data` 마운트 + fstab 등록 (`prjquota` 옵션 포함)
- [ ] `/data/teams`, `/data/ssh`, `/data/ssh_backups` 디렉터리 생성
- [ ] 네트워크 설정 (고정 IP)
- [ ] NVIDIA 드라이버 설치 + `nvidia-smi` 확인
- [ ] Docker + NVIDIA Container Toolkit 설치
- [ ] `dept-ml-ops` 리포지토리 클론
- [ ] `teamctl-xfs.sh` 및 관련 파일 `/opt/mlops/`에 배포
- [ ] compose.yaml 스켈레톤 생성
- [ ] GPU 모드 8 설정
- [ ] Docker 이미지 pull (또는 빌드)
- [ ] Bastion 초기 설정 (`bastion-init`) + 방화벽 규칙 (22 허용, 22031~22069 차단)
- [ ] NFS 클라이언트 설치 + `/mnt/nfs/teams` 마운트 + fstab 등록
- [ ] NFS 원격 제어용 SSH 키 설정 + 연결 테스트
- [ ] 모니터링 exporter 배포 + 방화벽 설정
- [ ] 중앙 Prometheus에 이 서버 등록 + scrape 확인
- [ ] 팀 생성 + 컨테이너 기동 + audit 검증
- [ ] Grafana에서 이 서버 메트릭 표시 확인
