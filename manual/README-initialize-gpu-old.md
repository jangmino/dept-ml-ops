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

### 1.3 Ubuntu 설치 시 파티션 설정 (Custom storage layout)

Ubuntu **Server** 설치기에서 스토리지 단계는 **"Custom storage layout"** 을 선택합니다. (Desktop 설치기의 "Something else"에 해당)

1. 대상 디스크(예: SAMSUNG 960GB)를 선택 → **`Reformat`** 으로 기존 파티션을 모두 제거하고 빈 GPT로 초기화합니다.
   > 파티션을 개별로 지우려 하면 *"Cannot delete a single partition from a device that already has partitions"* 에러가 날 수 있습니다. **디스크 단위 `Reformat`** 이 가장 확실합니다.
2. 디스크를 선택 → **`Use As Boot Device`** → ESP(약 1GB, `/boot/efi`)가 자동 생성됩니다.
3. 생긴 **free space** → `Add GPT Partition` → **120GB, ext4, 마운트 `/`** 로 생성합니다.
4. **나머지 공간(약 800GB)은 free space로 남겨둡니다.** (설치 중 만들지 않음)

| 파티션 | 크기 | 타입 | 마운트 | 비고 |
|--------|------|------|--------|------|
| ESP | ~1GB | FAT32 | `/boot/efi` | `Use As Boot Device`로 자동 생성 |
| `/dev/sda2` | 120GB | ext4 | `/` | OS (Docker 이미지가 `/var/lib/docker`에 쌓이므로 100GB보다 여유 있게) |
| free space | 나머지 | — | *생성 안 함* | 설치 후 XFS(`/data`)로 포맷 |

> ⚠️ **설치 USB 디스크(예: `VendorCo ...`)를 건드리지 마세요.** SAMSUNG 내장 디스크만 Reformat 합니다.
> **중요:** 데이터 영역(sda3)은 설치 과정에서 만들지 않습니다. 설치 완료 후 `sgdisk`로 생성하고 XFS 포맷합니다.

### 1.4 설치 완료 후 — /data 파티션 생성 + XFS 포맷

남은 free space 전체를 `sda3`로 만듭니다. `sgdisk -n 3:0:0`은 **직전 파티션 끝부터 디스크 끝까지 자동 정렬**하므로 offset 계산이 필요 없습니다 (parted의 수동 시작점 지정보다 안전 — 시작점이 sda2 끝보다 앞이면 겹쳐서 실패함).

```bash
sudo apt update && sudo apt install -y gdisk
sudo sgdisk -n 3:0:0 -t 3:8300 -c 3:team-volumes /dev/sda
sudo partprobe /dev/sda
lsblk /dev/sda        # sda3(약 773GiB) 생성 확인
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

고정 IP를 설정합니다. 인터페이스명은 서버마다 다를 수 있으므로(예: `eno1`/`eno2`), **케이블이 연결된(carrier UP) NIC** 를 쓰고, 재설치로 이름이 바뀌어도 안전하도록 **MAC 기반 `match`** 를 권장합니다.

> **팁:** Ubuntu 설치기 네트워크 단계에서 미리 고정 IP를 잡아두면, 재부팅 후 곧바로 사무실에서 SSH로 나머지 작업을 이어갈 수 있습니다 (설치 시 **OpenSSH server 설치 체크 필수**).

### 구서버 IP 배정

| 서버 | campus IP | 연결 NIC(예) |
|------|-----------|-------------|
| gpu-old1 | 210.125.91.90 | eno2 |
| gpu-old2 | 210.125.91.91 | eno2 |
| gpu-old3 | 210.125.91.92 | eno2 |
| gpu-old4 | 210.125.91.93 | eno2 |

```yaml
# /etc/netplan/00-installer-config.yaml (예: gpu-old1)
network:
  version: 2
  renderer: networkd
  ethernets:
    eno2:                              # 교내망 (관리용) — 기본 게이트웨이
      match: {macaddress: "d8:5e:d3:4e:10:68"}   # 서버별 실제 MAC로 교체
      set-name: eno2
      dhcp4: false
      addresses: [210.125.91.90/24]
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
      routes:
        - to: default
          via: 210.125.91.1
    eno1:                              # 내부망(있으면) — IP만, default route 없음
      match: {macaddress: "d8:5e:d3:4e:10:67"}
      set-name: eno1
      dhcp4: false
      addresses: [100.100.0.52/24]     # 내부망 사용 시에만
```

```bash
sudo chmod 600 /etc/netplan/00-installer-config.yaml
sudo netplan generate && sudo netplan apply
ip route | grep default    # default가 210.125.91.1 하나만 있어야 정상
```

> - **default route는 하나만** 두세요. 내부망(eno1) 등 보조 NIC에는 IP만 주고 default route를 넣지 않습니다 (라우팅 충돌 방지).
> - **BMC(IPMI) 관리 IP**(예: `100.100.0.x`)는 메인보드 펌웨어에 저장되어 **OS 재설치와 무관하게 유지**됩니다. netplan과 별개이며, BIOS에서 BMC factory reset만 하지 않으면 그대로입니다.

---

## 3. NVIDIA 드라이버 + Docker 설치

### 3.1 NVIDIA 드라이버

구서버 GPU는 **8× RTX A5000**(Ampere)입니다. gpu-new(중앙 서버)와 **드라이버 브랜치를 일치**시킵니다(현재 580 계열).

```bash
sudo apt update
sudo apt install -y ubuntu-drivers-common
ubuntu-drivers devices          # 지원 드라이버 확인 (nvidia-driver-580-server 존재 확인)

sudo apt install -y nvidia-driver-580-server   # gpu-new(580.x)와 동일 브랜치, server 변형
sudo reboot

# 재부팅 후 확인 (SSH 재접속)
nvidia-smi                      # Driver 580.x, RTX A5000 8개, CUDA 13.x
```

> **참고:** gpu-new에서 `nvidia-smi`로 현재 버전(예: 580.95.05)을 확인하고 같은 브랜치로 맞춥니다. `ubuntu-drivers`의 `recommended`(예: 595-open)와 다르더라도 **중앙과 브랜치 일치**를 우선합니다(DCGM exporter 호환). `-server` 변형이 데이터센터/헤드리스 서버에 적합하며, Secure Boot를 BIOS에서 꺼두면 DKMS 서명 절차가 생략됩니다.

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

# 확인 (드라이버가 CUDA 13이므로 13.0 베이스로 테스트)
sudo docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
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

> **전제:** 팀 이미지는 **gpu-new에서 빌드 후 Docker Hub에 push** 되어 있어야 pull이 됩니다. gpu-new에서 로컬 빌드만 하고 push하지 않았다면 아래 pull이 `not found`로 실패합니다.
>
> ```bash
> # (필요 시) gpu-new에서 먼저 push
> sudo docker login
> sudo docker push jangminnature/mlops:dept-20260208
> ```

```bash
# 구서버에서 pull (gpu-new와 동일 태그로 통일)
sudo docker pull jangminnature/mlops:dept-20260208

# 또는 로컬 빌드 (Hub 미사용 시)
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
sudo ufw allow 22/tcp              # bastion 진입 — enable 전에 반드시 먼저!
sudo ufw deny  22031:22069/tcp     # 컨테이너 SSH 외부 차단
sudo ufw enable                    # "disrupt ssh?" → y (22 이미 허용해서 안전)
sudo ufw status verbose
```

> ⚠️ **SSH 원격 작업 중 순서 주의:** `ufw enable`은 기존 SSH 연결을 끊을 수 있습니다. **반드시 `allow 22/tcp`를 먼저** 넣고 enable하세요. 잘못되면 BMC 웹콘솔로 접속해 `sudo ufw disable`로 복구합니다.

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
sudo ssh -i /opt/mlops/keys/nfsctl_ed25519 \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  nfsadmin@210.125.91.94 "sudo /opt/nfs/nfsctl.sh audit"
```

> **`sudo` 필수:** 키(`nfsctl_ed25519`)가 root 소유(600)이고 실제 `teamctl`도 root로 이 SSH를 호출하므로, 테스트도 `sudo`로 해야 키를 읽습니다. (일반 유저로 하면 `Load key ... Permission denied` → 비번 폴백)

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

## 트러블슈팅 (재설치 중 자주 만나는 것)

- **USB 뽑고 부팅했더니 "부팅 매체를 넣으라"는 경고** — BIOS 부팅순서가 아직 USB를 보고 있음. **F11 부팅메뉴 → `ubuntu`(UEFI) 항목** 선택. 이후 BIOS Boot Order에서 `ubuntu`를 1순위로 고정.
- **GRUB 메뉴 대신 `grub>` 프롬프트로 빠짐** — `normal` 입력 시 정상 메뉴로 복귀.
- **비번 오타로 로그인 불가** — 물리 콘솔/BMC에서 GRUB → recovery mode → `root` 셸 → `mount -o remount,rw /` → `passwd <user>`. (암호 몰라 재부팅도 못 하면 `Ctrl+Alt+Del` 또는 BMC power reset)
- **`systemctl is-active ssh` 가 `inactive`** — Ubuntu 24.04는 SSH가 **소켓 활성화**라 정상입니다. `systemctl is-active ssh.socket`(active)와 `ss -tlnp | grep ':22'`(LISTEN)로 판단하세요. 접속이 들어오면 `ssh.service`가 자동으로 뜹니다.
- **재설치 후 SSH 접속 시 "REMOTE HOST IDENTIFICATION HAS CHANGED"** — 호스트키가 새로 생성돼서 정상입니다. 클라이언트에서 `ssh-keygen -R <서버IP>` 후 재접속.
- **bastion 접속이 `Connection refused` / `stdio forwarding failed`** — bastion(jump) 인증은 됐으나 대상 컨테이너 포트가 안 열림. 대개 **컨테이너 미기동**이므로 `docker compose -f /opt/mlops/compose.yaml up -d <team>` 후 재시도.
- **`docker pull ... not found`** — gpu-new에서 이미지를 push하지 않음. §6 참고(먼저 push).

---

## 전체 초기화 체크리스트

- [ ] 기존 사용자에게 데이터 백업 안내 (유예 기간)
- [ ] Ubuntu 재설치 (신규 서버와 동일 버전) — **OpenSSH server 설치 체크**
- [ ] 파티션: `/dev/sda2`(ext4, 120GB, OS) + `sgdisk`로 `/dev/sda3`(XFS, 나머지, /data)
- [ ] `/data` 마운트 + fstab 등록 (`prjquota` 옵션 포함) + `state -p`로 ON 확인
- [ ] `/data/teams`, `/data/ssh`, `/data/ssh_backups` 디렉터리 생성
- [ ] 네트워크 설정 (고정 IP, MAC match, default route 하나만)
- [ ] NVIDIA 드라이버 설치 (`nvidia-driver-580-server`) + `nvidia-smi` 8-GPU 확인
- [ ] Docker + NVIDIA Container Toolkit 설치
- [ ] `dept-ml-ops` 리포지토리 클론
- [ ] `teamctl-xfs.sh` 및 관련 파일 `/opt/mlops/`에 배포
- [ ] compose.yaml 스켈레톤 생성
- [ ] GPU 모드 8 설정
- [ ] Docker 이미지 pull (gpu-new에서 push 선행) 또는 빌드
- [ ] Bastion 초기 설정 (`bastion-init`) + 방화벽 (22 허용 → `ufw enable` → 22031~22069 차단)
- [ ] NFS 클라이언트 설치 + `/mnt/nfs/teams` 마운트 + fstab 등록
- [ ] NFS 원격 제어용 SSH 키 설정 + **`sudo`로** 연결 테스트
- [ ] **스토리지 서버 방화벽이 이 서버 IP의 NFS 접근을 허용하는지 확인** (스토리지 매뉴얼 §5.4)
- [ ] 모니터링 exporter 배포 + 방화벽 설정
- [ ] 중앙 Prometheus에 이 서버 등록 + scrape 확인 (타깃 3개 up)
- [ ] 팀 생성 + 컨테이너 기동 + audit 검증 (**UID/포트가 팀번호와 일치**하는지)
- [ ] Grafana에서 이 서버 메트릭 표시 확인
