# 🗄️ 스토리지 서버 초기 세팅 매뉴얼

> RAID-6, ~100TB NFS 스토리지 서버 기준
>
> 딥러닝 서버에서 팀별 대용량 데이터(데이터셋, 체크포인트)를 NFS로 공유하기 위한 스토리지 서버 초기화 절차입니다.

---

## 전체 흐름

```
/dev/sda (≈102T, RAID-6)
  → XFS + prjquota
  → /nfs/teams/<team>
  → NFSv4 export
  → 딥러닝 서버에서 mount (/mnt/nfs/teams)
  → 컨테이너에 bind mount (/nfs/team)
```

---

## 1. 디스크 파티션 생성 + XFS 포맷

### 1.1 디스크 상태 확인

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS /dev/sda
```

### 1.2 GPT 파티션 생성

```bash
sudo parted /dev/sda --script mklabel gpt
sudo parted /dev/sda --script mkpart primary 0% 100%

# 커널 파티션 테이블 재인식
sudo partprobe /dev/sda
```

### 1.3 XFS 포맷 (대용량 권장 옵션)

```bash
sudo mkfs.xfs -f -m reflink=1,crc=1 /dev/sda1
```

---

## 2. 마운트 + fstab 등록

### 2.1 마운트 포인트 생성

```bash
sudo mkdir -p /nfs/teams
```

### 2.2 UUID 확인

```bash
sudo blkid /dev/sda1
# 출력 예:
# /dev/sda1: UUID="1f9fef88-2bda-4748-87c4-ffc43c037e84" BLOCK_SIZE="4096" TYPE="xfs" ...
```

### 2.3 fstab 등록

`/etc/fstab` 맨 아래에 추가 (UUID는 위 결과로 교체):

```
UUID=<위에서 확인한 UUID>  /nfs  xfs  defaults,noatime,prjquota  0  0
```

### 2.4 마운트 적용

```bash
sudo systemctl daemon-reload
sudo mount -a
df -h /nfs
```

### 2.5 XFS Project Quota 상태 확인

```bash
sudo xfs_quota -x -c "state" /nfs
```

---

## 3. nfsadmin 계정 생성

딥러닝 서버에서 SSH를 통해 nfsctl.sh를 원격 호출할 때 사용하는 전용 계정입니다.

### 3.1 계정 생성

```bash
sudo adduser nfsadmin
# 암호 설정

sudo usermod -aG sudo nfsadmin
```

### 3.2 nfsctl.sh 무암호 sudo 허용

```bash
# sudoers 파일 생성
sudo visudo -f /etc/sudoers.d/nfsadmin-nfsctl

# 아래 한 줄 입력 후 저장
nfsadmin ALL=(root) NOPASSWD: /opt/nfs/nfsctl.sh

# 권한 고정
sudo chmod 0440 /etc/sudoers.d/nfsadmin-nfsctl
```

### 3.3 SSH 키 인증 활성화

`/etc/ssh/sshd_config`에서 활성화 확인:

```
PubkeyAuthentication yes
```

확인 및 재시작:

```bash
sudo sshd -T | grep -i pubkeyauthentication
sudo systemctl restart ssh
```

---

## 4. 딥러닝 서버 SSH 키 등록

딥러닝 서버의 teamctl-xfs.sh가 이 스토리지 서버의 nfsctl.sh를 SSH로 호출합니다.

> **전제:** 딥러닝 서버에서 SSH 키가 이미 생성되어 있어야 합니다.
> (`/opt/mlops/keys/nfsctl_ed25519.pub` — 생성 절차는 [README-initialize-gpu.md](README-initialize-gpu.md) 7.4절 참고)

### 4.1 nfsadmin SSH 디렉터리 준비

```bash
sudo -u nfsadmin mkdir -p /home/nfsadmin/.ssh
sudo chmod 700 /home/nfsadmin/.ssh
sudo -u nfsadmin touch /home/nfsadmin/.ssh/authorized_keys
sudo chmod 600 /home/nfsadmin/.ssh/authorized_keys
```

### 4.2 공개키 등록

딥러닝 서버에서 확인한 공개키를 authorized_keys에 추가합니다.

```bash
sudo bash -lc 'echo "<딥러닝 서버 공개키 내용>" >> /home/nfsadmin/.ssh/authorized_keys'
sudo chown -R nfsadmin:nfsadmin /home/nfsadmin/.ssh
```

### 4.3 연결 테스트 (딥러닝 서버에서 실행)

```bash
ssh -i /opt/mlops/keys/nfsctl_ed25519 \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  nfsadmin@210.125.91.94 "sudo /opt/nfs/nfsctl.sh audit"
```

---

## 5. NFS 서버 설정 (NFSv4)

### 5.1 패키지 설치

```bash
sudo apt update
sudo apt install -y nfs-kernel-server
```

### 5.2 NFS Export 설정

`/etc/exports`에 추가:

```
/nfs        *(rw,fsid=0,no_subtree_check,async)
/nfs/teams  *(rw,no_subtree_check,async)
```

> NFSv4는 pseudo root를 사용합니다. `/nfs`를 루트로, `/nfs/teams`를 서브로 export합니다.

### 5.3 반영

```bash
sudo mkdir -p /nfs/teams
sudo chown root:root /nfs/teams
sudo chmod 755 /nfs/teams

sudo exportfs -ra
sudo exportfs -v
sudo systemctl restart nfs-kernel-server
```

---

## 6. nfsctl.sh 배포

### 6.1 스크립트 설치

```bash
sudo mkdir -p /opt/nfs
sudo cp ~/work/my_dockers/dept-mlops/nfsctl.sh /opt/nfs/nfsctl.sh
sudo chmod +x /opt/nfs/nfsctl.sh
```

### 6.2 초기 점검

```bash
sudo /opt/nfs/nfsctl.sh init
```

### 6.3 팀 생성 예시

UID/GID는 딥러닝 서버의 팀 컨테이너 정책과 동일하게 맞춥니다.

```bash
# team01: uid=12001, gid=12001
sudo /opt/nfs/nfsctl.sh create team01 --uid 12001 --gid 12001 --soft 1950G --hard 2000G
```

### 6.4 확인

```bash
sudo /opt/nfs/nfsctl.sh who team01
sudo /opt/nfs/nfsctl.sh quota
sudo /opt/nfs/nfsctl.sh audit
```

### 6.5 쿼터 변경

```bash
sudo /opt/nfs/nfsctl.sh resize team01 --soft 2950G --hard 3000G
```

### 6.6 팀 삭제

```bash
# 쿼터/매핑만 삭제 (디렉터리 보존)
sudo /opt/nfs/nfsctl.sh remove team01

# 디렉터리까지 삭제
sudo /opt/nfs/nfsctl.sh remove team01 --purge-dir
```

---

## 7. nfsctl.sh 전체 명령 레퍼런스

```
sudo /opt/nfs/nfsctl.sh init
sudo /opt/nfs/nfsctl.sh create TEAM --uid UID --gid GID --soft 950G --hard 1000G
sudo /opt/nfs/nfsctl.sh resize TEAM --soft 950G --hard 1000G
sudo /opt/nfs/nfsctl.sh who TEAM
sudo /opt/nfs/nfsctl.sh remove TEAM [--purge-dir]
sudo /opt/nfs/nfsctl.sh quota
sudo /opt/nfs/nfsctl.sh audit
```

> **참고:** 일반적으로 nfsctl.sh를 직접 실행할 필요 없이, 딥러닝 서버에서 `teamctl-xfs.sh create --nfs ...`를 실행하면 SSH를 통해 자동 호출됩니다.

---

## 권장 운영 정책

### UID/GID 정합성

NFS는 UID/GID 기반 권한이므로, 딥러닝 서버 컨테이너의 UID/GID와 스토리지 서버의 팀 디렉터리 소유자가 반드시 일치해야 합니다.

| 팀 | 컨테이너 UID:GID | NFS 디렉터리 소유자 |
|----|-------------------|---------------------|
| team01 | 12001:12001 | 12001:12001 |
| team02 | 12002:12002 | 12002:12002 |

### root_squash

`/etc/exports`에 별도 `no_root_squash`는 설정하지 않습니다. 기본 `root_squash` 유지가 안전합니다.

### 백업/스냅샷

RAID는 디스크 장애에 대비하지만 사용자 실수(삭제)는 보호하지 못합니다. 중요 체크포인트에 대한 스냅샷/백업 정책을 추후 수립하세요.

---

## 전체 초기화 체크리스트

- [ ] /dev/sda 파티션 생성 + XFS 포맷 (`reflink=1,crc=1`)
- [ ] `/nfs` 마운트 + fstab 등록 (`prjquota` 옵션 포함)
- [ ] XFS Project Quota 상태 확인
- [ ] `nfsadmin` 계정 생성 + sudo 설정
- [ ] SSH 키 인증 활성화 + 딥러닝 서버 공개키 등록
- [ ] NFS 패키지 설치 + `/etc/exports` 설정 + 서비스 재시작
- [ ] `nfsctl.sh` 배포 (`/opt/nfs/`) + `init` 실행
- [ ] 딥러닝 서버에서 연결 테스트: `nfsctl.sh audit` 원격 호출 성공
- [ ] 딥러닝 서버에서 NFS 마운트 확인: `df -h /mnt/nfs/teams`
