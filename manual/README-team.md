# 🖥️ GPU 서버 팀 운영 가이드 — 팀원용

> VS Code + Remote-SSH + Team Container 환경
>
> 서버 사용 전 **반드시 전체 내용을 숙지**해 주세요.

---

## 원칙 요약

- 접속은 **SSH 키 인증만** 허용 (비밀번호 로그인 불가)
- 작업은 반드시 **`/workspace` 또는 `~`** 에서 진행
- 대용량 데이터셋·체크포인트는 **`/nfs/team`** 에 저장
- 장시간 학습은 **`screen` 필수**
- 파이썬 환경/패키지는 **`uv` 의무 사용**
- **금지 행위 필독** → [README-team-policy.md](README-team-policy.md) (외부 터널링·자동 respawn·상시 서비스 호스팅 등)

---

## 1. 팀별 접속 정보

아래 표에서 본인 팀의 접속 정보를 확인하세요. **관리자가 팀 생성 후 실제 정보를 안내합니다.**

### gpu-new (신규 서버, GPU 4장)

| TEAM | HOST | PORT | GPU | 로컬 QUOTA (Soft/Hard) | NFS QUOTA (Soft/Hard) |
|------|------|------|-----|------------------------|-----------------------|
| team01 | `<서버IP>` | 22021 | 0 | 290G / 300G | 1950G / 2000G |
| team02 | `<서버IP>` | 22022 | 1 | 290G / 300G | 1950G / 2000G |
| team03 | `<서버IP>` | 22023 | 2 | 290G / 300G | 1950G / 2000G |
| team04 | `<서버IP>` | 22024 | 3 | 290G / 300G | 1950G / 2000G |

### gpu-old1~4 (구 서버, GPU 8장)

| TEAM | HOST | PORT | GPU | 서버 | 비고 |
|------|------|------|-----|------|------|
| team11-18 | `<서버IP>` | 22031-22038 | 0-7 | gpu-old1 | |
| team21-28 | `<서버IP>` | 22041-22048 | 0-7 | gpu-old2 | |
| team31-38 | `<서버IP>` | 22051-22058 | 0-7 | gpu-old3 | |
| team41-48 | `<서버IP>` | 22061-22068 | 0-7 | gpu-old4 | |

> **팁:** 팀 번호의 십의 자리가 서버를 나타냅니다. team31 → gpu-old3.

---

## 2. SSH 키 생성

> **주의:** `-C` 옵션에 반드시 `팀명/팀원식별자` 형식을 사용하세요.
> 예: `team01/jangmin`, `team01/minji`, `team02/soyeon`
> 파일명도 아래 예시 참고하여 팀명_팀원식별자로 하길 권장

### Mac / Linux

```bash
ssh-keygen -t ed25519 -C "team01/jangmin" -f ~/.ssh/id_ed25519_team01_jangmin
cat ~/.ssh/id_ed25519_team01_jangmin.pub
```

### Windows (PowerShell)

```powershell
ssh-keygen -t ed25519 -C "team01/jangmin" -f $env:USERPROFILE\.ssh\id_ed25519_team01_jangmin
type $env:USERPROFILE\.ssh\id_ed25519_team01_jangmin.pub
```

### 관리자에게 전달

- ✅ **전달할 것:** `.pub` 공개키 내용 (한 줄)
- ❌ **절대 공유 금지:** 비밀키 파일 (`id_ed25519_...`)

---

## 3. VS Code Remote-SSH 접속 설정

### Bastion(2단 접속) 개념 — 왜 두 개의 Host 블록인가

학교 방화벽 정책상 외부에서는 서버의 **SSH 표준 포트(22번) 하나**만 접근 가능합니다. 컨테이너 포트(22021 등)에 직접 접속할 수 없으므로, 2단계로 들어갑니다:

```
본인 노트북 ──(외부망)──> <GPU서버>:22 (bastion = jump 계정)
                              │
                              └─(서버 내부)──> 본인 팀 컨테이너:<팀포트>
```

- **Bastion**: 각 GPU 서버의 SSH 22번. `jump` 공용 계정으로만 받고, 셸 차단 + 본인 팀 포트 외엔 거부.
- **컨테이너**: 본인 팀 포트 (위 표의 PORT). bastion 입장에서는 `127.0.0.1:<팀포트>`로 보임.

SSH의 **`ProxyJump`** 기능이 이 두 단계를 한 줄 명령으로 자동 처리합니다. 한 번 설정해두면 `ssh ss-team01`만 치면 끝.

### SSH config 작성

SSH config 파일 위치:
- Mac/Linux: `~/.ssh/config`
- Windows: `C:\Users\<사용자>\.ssh\config`

**본인 팀에 맞춰** 두 블록을 추가합니다. 예시는 team01(gpu-new, PORT=22021):

```
# 1) Bastion — 본인 팀 서버에 하나
Host bastion-gpu-new
  HostName 210.125.91.95
  Port 22
  User jump
  IdentityFile ~/.ssh/id_ed25519_team01_jangmin
  IdentitiesOnly yes

# 2) 팀 컨테이너 — bastion을 ProxyJump으로 경유
Host ss-team01
  HostName 127.0.0.1
  Port 22021
  User team01
  IdentityFile ~/.ssh/id_ed25519_team01_jangmin
  IdentitiesOnly yes
  ProxyJump bastion-gpu-new
  ServerAliveInterval 30
```

> **포인트**: `ss-team01` 블록의 `HostName 127.0.0.1`은 본인 노트북이 아니라 **bastion이 본 자기 localhost** 라는 의미입니다. bastion이 받은 요청을 같은 호스트의 22021 포트로 터널링합니다.
>
> **본인이 다른 서버 팀이면** (예: team23 → gpu-old2 → 22043): `bastion-gpu-old2` 블록을 추가하고, 컨테이너 블록의 `ProxyJump`를 그것으로 바꾸세요. 본인 팀이 속한 서버의 bastion만 추가하면 됩니다 (모든 서버를 다 적을 필요 없음).

### 서버별 bastion HostName 참고표

| 서버 | Bastion HostName |
|------|------------------|
| gpu-new | `210.125.91.95` |
| gpu-old1 | `<관리자 안내>` |
| gpu-old2 | `<관리자 안내>` |
| gpu-old3 | `<관리자 안내>` |
| gpu-old4 | `<관리자 안내>` |

### 접속 방법

1. VS Code → Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`)
2. `Remote-SSH: Connect to Host...` 선택
3. `ss-team01` 선택

터미널에서 확인할 때:

```bash
ssh ss-team01
```

> 첫 접속 시 호스트 키 확인을 **두 번** 묻습니다 (bastion + 컨테이너). 각각 `yes`로 응답하세요.

---

## 4. 작업 위치 규칙

컨테이너의 `/` (root, overlay)에 파일을 쌓으면 서버 디스크를 불필요하게 점유합니다.

### 컨테이너 내부 디렉터리 구조

| 경로 | 용도 | 저장소 | 할당량 |
|------|------|--------|--------|
| `/workspace` (= `~`) | 코드, 가상환경, 소규모 실험 | GPU 서버 로컬 (NVMe) | 팀별 로컬 QUOTA |
| `/nfs/team` | 대용량 데이터셋, 체크포인트, 모델 가중치 | NFS 스토리지 서버 (RAID-6) | 팀별 NFS QUOTA |

```bash
# ✅ 코드 및 가상환경
cd /workspace

# ✅ 대용량 데이터셋·체크포인트
ls /nfs/team
```

> **주의:** `/nfs/team`은 네트워크 스토리지이므로, 작은 파일을 대량으로 읽고 쓰는 작업(예: 수만 개의 작은 이미지)보다는 대용량 파일 저장에 적합합니다. 학습 시 데이터 로딩 속도가 중요하다면 `/workspace`로 복사 후 사용하세요.

---

## 5. GPU 사용 규칙

각 팀 컨테이너는 할당된 GPU만 보이도록 격리되어 있으므로, GPU ID를 직접 지정할 필요 없이 컨테이너 안에서 학습/추론을 실행하면 됩니다.

### GPU 상태 확인

```bash
nvidia-smi
```

### ⛔ 금지 사항

- 호스트(컨테이너 밖)에서 직접 학습을 실행하는 행위
- 다른 팀 컨테이너에 접근하는 행위

### 🚨 문제 발생 시

`nvidia-smi`에서 GPU가 보이지 않거나 에러가 발생하면 **즉시 관리자에게 문의**하세요.

---

## 6. 장시간 학습은 screen 필수

VS Code 터미널에서 그냥 실행하면 네트워크 단절이나 VS Code 종료 시 학습이 중단됩니다.

```bash
# screen 시작
screen -S MyRUN

# screen 안에서 학습 실행
cd /workspace
python train.py

# detach (백그라운드 지속): Ctrl+A → D

# 다시 붙기
screen -r MyRUN

# screen 목록 보기
screen -ls
```

**팁:** 로그를 파일로 남기세요.

```bash
python train.py 2>&1 | tee -a train.log
```

---

## 7. 파이썬/패키지 설치는 uv 의무

> ❌ `pip install ...` 직접 사용 금지
> ✅ 항상 `uv pip install ...`

```bash
# 가상환경 생성
cd /workspace
uv venv .venv --python=3.13

# 가상환경 활성화
source .venv/bin/activate

# 패키지 설치
uv pip install unsloth vllm

# 실행
python my-train.py
```

---

## 8. 디스크 사용량 확인

```bash
# 로컬 스토리지 (코드, 가상환경)
df -h /workspace

# NFS 스토리지 (데이터셋, 체크포인트)
df -h /nfs/team
```

---

## 9. 자주 발생하는 문제

### (A) `REMOTE HOST IDENTIFICATION HAS CHANGED` 경고

호스트키가 바뀐 경우입니다. 어느 단(bastion인지 컨테이너인지)에서 났는지 메시지를 잘 보세요.

**컨테이너 쪽 (대부분의 경우, 컨테이너 교체 후):**
```bash
ssh-keygen -R "[127.0.0.1]:22021"
# 본인 팀 포트로 치환
```

**Bastion 쪽 (서버 재설치 후 등 드문 경우):**
```bash
ssh-keygen -R "[210.125.91.95]:22"
# 본인 팀 서버 IP로 치환
```

이후 재접속하면 호스트키 확인을 다시 묻습니다.

### (B) 접속이 안 될 때

```bash
ssh -vvv ss-team01
```

출력 로그를 관리자에게 전달하세요.

### (C) `/nfs/team`이 보이지 않거나 접근 불가

NFS 마운트 문제일 수 있습니다. 관리자에게 문의하세요.

---

## 10. 추천 작업 템플릿

```bash
cd /workspace
uv venv .venv --python=3.13
source .venv/bin/activate
uv pip install -r requirements.txt

# 대용량 데이터셋은 NFS에서 참조
ls /nfs/team/datasets/

screen -S MyRUN
python train.py 2>&1 | tee -a train.log
# Ctrl+A, D 로 detach
```

---

## 작업 전 체크리스트

- [ ] 컨테이너 안에서 실행 중이다 → `hostname` 명령으로 확인
- [ ] 작업 디렉터리는 `/workspace` 또는 `~` 이다
- [ ] `nvidia-smi`에서 GPU가 정상적으로 보인다
- [ ] 장시간 학습은 `screen`에서 실행 중이다
- [ ] 패키지 설치에 `uv pip install`을 사용했다
- [ ] 대용량 파일은 `/nfs/team`에 저장했다
