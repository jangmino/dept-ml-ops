# 🧪 Bastion + ProxyJump POC (서버별 bastion 구조)

> 외부 노출 포트를 **서버당 1개 (총 5포트)** 로 줄이는 방식의 시범 검증 문서.
> 각 GPU 서버에 자체 bastion(jump 시스템 계정)을 두는 **분산 구조**.
>
> **이 문서는 임시 검증용입니다.** 만족스러우면 본 매뉴얼(`README-admin.md`, `README-team.md`, `README-initialize-gpu.md` 등) 및 `teamctl-xfs.sh`를 일괄 수정합니다.

---

## 1. 배경

학교 IT 운영팀의 방화벽 정책 변경이 예고되어 있습니다. 현재까지는 22번(SSH)만 VPN 없이 외부 차단이었고, 학과 컨테이너는 `22021~22069` 비표준 포트를 써서 외부에서 직접 접근 가능했습니다.

정책 강화 후엔 이 비표준 포트 대역도 차단될 가능성이 큽니다. 대응안:

- **1안 (협상)**: 포트 대역 `22021~22069`를 VPN 예외 허용 요청
- **2안 (대안)**: 각 GPU 서버에 bastion을 두고, 학생은 그 서버의 bastion만 거쳐 해당 서버의 컨테이너로 진입 → **이 문서가 다루는 방식**

2안의 의미: 외부 노출 포트가 50개 → 5개로 축소. "**GPU 서버 5대의 표준 SSH 포트**" 라는 가장 평범한 방화벽 예외로 정규화됨.

---

## 2. 용어 해설

| 용어 | 뜻 |
|------|-----|
| **Bastion (베스천) Host / Jump Host** | 외부에서 접근 가능한 관문 서버. 다른 내부 자원은 외부 직접 접근 불가. 공격이 들어와도 여기 한 곳만 막으면 된다는 의미의 요새. 본 POC에선 **각 GPU 서버 자신이 자기 서버용 bastion 역할**을 겸함. |
| **ProxyJump** | OpenSSH 7.3(2016)에 추가된 기능. `ssh -J <중간호스트> <목적지>` 또는 `~/.ssh/config`의 `ProxyJump` 키워드. 중간 호스트(=bastion)를 거쳐 자동으로 최종 호스트에 접속한다. |
| **TCP forwarding (포트 포워딩)** | SSH 연결을 터널로 삼아 다른 호스트의 TCP 포트로 패킷을 중계하는 기능. ProxyJump의 실제 동작 원리. |
| **PermitOpen** | sshd 설정 또는 `authorized_keys` 옵션. **이 SSH 세션이 어느 호스트:포트로 터널을 열 수 있는지** 화이트리스트 지정. |
| **restrict** | `authorized_keys` 줄 앞에 붙는 옵션. PTY, 에이전트 포워딩, X11, 명령 실행 등 **모든 부가 권한을 차단**하고 `permitopen` 등으로 필요한 것만 다시 열어주는 가장 엄격한 모드. **단 일부 OpenSSH 빌드(예: Ubuntu 24.04)에서 `restrict + permitopen` 조합이 의도대로 동작하지 않는 사례가 있어, 본 POC는 키 단위 `restrict` 대신 sshd `Match User` 블록(§3 참고)에서 정책을 일괄 적용하고, 키 단위에는 `permitopen`만 둠**. |
| **ForceCommand** | sshd 설정 항목. 어떤 명령을 받든 **이 명령만** 실행. `/usr/sbin/nologin`을 걸면 셸은 안 떠도 ProxyJump 터널링은 정상 동작 (TCP 채널은 셸과 무관). |
| **fingerprint (지문)** | 공개키의 해시. SSH 로그에 어떤 키로 인증되었는지 fingerprint가 남으므로, 키를 학생별로 1개 발급해두면 누가 들어왔는지 추적 가능. |

---

## 3. 원리

### 현재 (직접 접속)

```
학생 노트북 ──(인터넷)──> 학교 방화벽 ──> gpu-new:22025 (team05 컨테이너)
                            ↑
                  방화벽 정책 강화되면 차단
```

### POC 구조 (서버별 bastion)

각 GPU 서버는 **자기 서버 학생들의 bastion** 역할을 동시에 수행. 외부에서 보이는 건 각 서버의 SSH 표준 포트 1개씩.

```
┌─ gpu-new ──────────────────────────────────────┐
│                                                │
│  학생 ──> :22 (jump 계정, 셸 없음)              │
│            │                                   │
│            ▼ 같은 호스트 localhost 터널          │
│          team05 컨테이너 :22025                 │
│          team06 컨테이너 :22026                 │
│          ...                                   │
└────────────────────────────────────────────────┘

┌─ gpu-old2 ─────────────────────────────────────┐
│                                                │
│  학생 ──> :22 (jump 계정, 셸 없음)              │
│            │                                   │
│            ▼ 같은 호스트 localhost 터널          │
│          team21 컨테이너 :22041                 │
│          team23 컨테이너 :22043                 │
│          ...                                   │
└────────────────────────────────────────────────┘

(gpu-old1, gpu-old3, gpu-old4도 동일 패턴)
```

핵심 포인트:

1. **각 bastion은 자기 호스트의 `127.0.0.1`로만 터널을 뚫는다.** 서버 간 내부망 경유가 발생하지 않음. `permitopen`이 전 서버 통일된 `127.0.0.1:<포트>` 형태.
2. **호스트 학생 계정 0개 유지.** 각 서버에 공용 `jump` 계정 1개만 있고, 학생 식별은 키 지문으로.
3. **장애 격리.** gpu-old2 bastion이 죽어도 다른 서버 학생들은 영향 없음. gpu-new의 bastion이 침투당해도 gpu-old* 팀에 자동 접근권이 안 생김.
4. **`authorized_keys` 줄별 화이트리스트.** 키 1개로는 자기 팀의 단일 포트로만 터널 가능. 키 유출 영향 최소화.
5. **외부 노출 50포트 → 5포트** (서버당 1).

---

## 4. 다른 안과의 비교

| 항목 | 현재 | 단일 bastion (검토했으나 미채택) | **서버별 bastion (채택)** |
|------|------|--------------------------------|--------------------------|
| 외부 노출 포트 | 50 | 1 | 5 (서버당 1) |
| 호스트 학생 계정 | 없음 | 없음 | **없음** ✓ |
| 단일 장애점 | 서버별 | gpu-new에 외부 접속 전체 집중 | 서버별 (격리 유지) |
| 내부망 경유 | 불필요 | gpu-new → gpu-old* 라우팅 필요 | 불필요 (localhost) |
| `teamctl-xfs.sh` 수정 | — | 원격 SSH로 gpu-new 호출 추가 | 로컬 파일 1줄 추가 |
| 보안 영향 격리 | — | 약 (1점 침투 → 전 서버 접근) | 강 (서버 단위 격리) |
| 현 아키텍처 일치도 | — | 낮음 (gpu-new에 새 특별 역할) | 높음 (서버별 자율 패턴 유지) |

---

## 5. POC 범위 / 가정

- **1차 검증**: GPU 서버 1대(예: **gpu-new**)에서 셋업하고 동작/권한 확인.
- **2차 검증 (Step 9)**: 또 다른 서버(예: gpu-old2)에 같은 절차를 반복해 **패턴 재현성**과 **서버 간 권한 격리**를 확인. 이것이 "서버별 bastion" 안의 본질적 검증 포인트.
- **테스트 팀**: 신규 팀(team99 등)을 만들거나 기존 팀 중 하나를 재활용.
- **방화벽 변경 없이도 검증 가능**: "ProxyJump 경로 정상 동작 + 권한 우회 차단"이 우선 검증 대상. 외부망 실측은 별도(Step 10).

본 문서는 1차 대상으로 **gpu-new + team05 (포트 22025)** 를 예시로 사용.

---

## 6. 단계별 진행

### Step 1. 테스트 팀 컨테이너 준비 (gpu-new에서)

기존 팀을 재활용해도 되고, 새로 만든다면:

```bash
sudo /opt/mlops/teamctl-xfs.sh create team05 --gpu 0 --size 50G --soft 45G
sudo /opt/mlops/teamctl-xfs.sh audit | grep team05
```

team05 → 포트 `22025` (= 22020 + 5).

### Step 2. Bastion 시스템 계정 생성 (gpu-new에서)

```bash
sudo useradd -m -s /usr/sbin/nologin jump
sudo mkdir -p /home/jump/.ssh
sudo chown jump:jump /home/jump/.ssh
sudo chmod 700 /home/jump/.ssh
sudo touch /home/jump/.ssh/authorized_keys
sudo chown jump:jump /home/jump/.ssh/authorized_keys
sudo chmod 600 /home/jump/.ssh/authorized_keys
```

`nologin` 셸이지만 ProxyJump(TCP 포워딩)는 셸과 무관하게 동작합니다.

### Step 3. sshd `Match User` 블록으로 jump 정책 일괄 적용 (gpu-new에서)

전역 sshd 설정 사전 확인:

```bash
sudo sshd -T | grep -E '^(allowtcpforwarding|allowusers)'
```

- `allowtcpforwarding yes` 확인. `no`면 `/etc/ssh/sshd_config`에서 활성화 필요.
- `AllowUsers` 항목이 있다면 `jump`를 추가해야 합니다.

**jump 계정 전용 정책 파일 생성** — `/etc/ssh/sshd_config.d/jump.conf`:

```
Match User jump
    ForceCommand /usr/sbin/nologin
    AllowTcpForwarding yes
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
    GatewayPorts no
```

```bash
sudo systemctl reload ssh
```

각 항목 의미:
- `ForceCommand /usr/sbin/nologin` — **세션 채널**(셸/명령 실행) 시 무조건 `nologin`만 실행. 셸 차단의 결정적 한 줄. ProxyJump이 쓰는 **direct-tcpip 채널은 영향 없음** (채널 종류가 다름).
- `AllowTcpForwarding yes` — ProxyJump 동작에 필요 (전역이 `no`면 여기서 명시적으로 켬)
- `PermitTTY no` — PTY 할당 차단 (`ForceCommand`와 이중 안전장치)
- `X11Forwarding no` / `AllowAgentForwarding no` / `PermitTunnel no` / `GatewayPorts no` — 각종 부가 통로 차단

> 이 블록 한 곳에 jump 계정 정책을 모두 모아두면, 학생 키를 N개 추가해도 `authorized_keys` 라인은 **목적지(`permitopen`)만** 적으면 됩니다. 정책이 키마다 반복되지 않아 운영이 깔끔.

### Step 4. 키 발급 및 등록

#### 4-1. 테스트용 키 생성 (학생 역할의 본인 노트북에서)

```bash
ssh-keygen -t ed25519 -C "bastion-poc/jangmin" -f ~/.ssh/id_ed25519_bastion_poc
cat ~/.ssh/id_ed25519_bastion_poc.pub
```

#### 4-2. 컨테이너에 키 등록 (gpu-new에서)

기존 흐름 그대로:

```bash
sudo /opt/mlops/teamctl-xfs.sh add-key team05 --key "ssh-ed25519 AAAA... bastion-poc/jangmin"
```

#### 4-3. 같은 서버의 Bastion authorized_keys에 등록 (gpu-new에서)

```bash
PORT=22025   # team05의 SSH 포트
echo "permitopen=\"127.0.0.1:${PORT}\" ssh-ed25519 AAAA... bastion-poc/jangmin" \
  | sudo tee -a /home/jump/.ssh/authorized_keys
```

키 단위에 적는 것은 **`permitopen` 하나뿐**입니다:
- `permitopen="127.0.0.1:22025"` — 이 키로는 **오직 자기 팀 포트**로만 터널 가능 (키마다 달라야 하는 유일한 항목)

셸 차단·PTY 차단·X11/Agent/Tunnel 차단 등은 **§3의 `Match User jump` 블록이 sshd 레벨에서 일괄 적용**합니다. 키 단위 옵션을 최소로 유지해 학생 N명 확장 시에도 라인이 단순.

> 서버별 bastion이라 `permitopen` 호스트가 **항상 `127.0.0.1`**. 다른 서버 IP를 알 필요도, 등장시킬 필요도 없음. 이 단순함이 본 안의 강점.

### Step 5. 학생 측 SSH config

본인 노트북 `~/.ssh/config`:

```sshconfig
Host bastion-gpu-new
    HostName 210.125.91.95
    Port 22
    User jump
    IdentityFile ~/.ssh/id_ed25519_bastion_poc
    IdentitiesOnly yes

Host team05
    HostName 127.0.0.1
    Port 22025
    User team05
    IdentityFile ~/.ssh/id_ed25519_bastion_poc
    IdentitiesOnly yes
    ProxyJump bastion-gpu-new
```

> `HostName 127.0.0.1`은 **bastion이 보는 자기 localhost** 라는 의미입니다 (학생 노트북의 localhost가 아님). `HostName`은 항상 bastion이 해석.
>
> `permitopen`에 적은 문자열(`127.0.0.1:22025`)과 클라이언트가 요청하는 표기가 **정확히 일치**해야 합니다. 두 곳 모두 `127.0.0.1`로 통일.

### Step 6. 정상 경로 접속 시험 ✅

```bash
ssh team05
```

기대 결과:
- bastion에서 한 번, 컨테이너에서 한 번 키 인증
- 컨테이너 안 셸 프롬프트 진입
- `whoami` → `team05`
- `nvidia-smi` → 할당 GPU 보임

### Step 7. 권한 우회 시도 (negative test) ❌

**7-1. bastion에 직접 셸 접속 시도**

```bash
ssh bastion-gpu-new
```

기대 출력 (Ubuntu 기준):
```
PTY allocation request failed on channel 0           ← no-pty 작동
Welcome to Ubuntu 24.04 ... (긴 MOTD 출력)            ← sshd가 셸 실행 전 표준 배너
...
This account is currently not available.            ← nologin 셸 = 셸 차단 ✓
Connection to 210.125.91.95 closed.                  ← 즉시 종료
```

> ⚠️ Ubuntu MOTD가 길어서 "원격 셸로 들어온 것"처럼 보이지만, **결정적 메시지는 마지막 두 줄**입니다. `whoami` 등을 쳤을 때 결과가 본인 노트북 로컬 사용자라면 이미 ssh가 끊겨 로컬 셸로 복귀한 상태. (선택) `sudo touch /home/jump/.hushlogin` 으로 MOTD를 끄면 출력이 더 명확해집니다.

**7-2. 허용되지 않은 다른 팀 포트로 ProxyJump 시도**

```bash
ssh -J bastion-gpu-new -p 22026 team06@127.0.0.1
# 기대: "channel 0: open failed: administratively prohibited"
```

`permitopen`이 22025만 허용했으므로 22026으로의 터널 시도는 bastion에서 거부됨.

**7-3. bastion 우회 직접 접속 (방화벽 변경 후 시나리오)**

방화벽 변경 전엔 학교 외부에서 직접 접속(`ssh -p 22025 team05@210.125.91.95`)도 됩니다. 변경 후에는 이 경로가 차단되는지 Step 10에서 검증.

### Step 8. 로그·감사 확인

**bastion 로그 (gpu-new):**

```bash
sudo journalctl -u ssh -n 100 --no-pager | grep jump
# 또는
sudo tail -n 100 /var/log/auth.log | grep jump
```

확인 사항:
- `Accepted publickey for jump from <학생IP> ... ED25519 SHA256:<지문>`
- `Failed channel request` 또는 `administratively prohibited` — negative test 흔적

**활성 터널:**

```bash
sudo lsof -iTCP -sTCP:ESTABLISHED -u jump
```

### Step 9. 또 다른 서버에서 패턴 재현 (gpu-old2) — **핵심 검증**

본 POC의 본질적 검증. gpu-old2에서 동일 절차를 반복하고, **서버 간 권한 격리**가 실제로 성립하는지 확인합니다.

**gpu-old2에서 Step 2~3 반복** (jump 계정, sshd 설정).

**gpu-old2에서 컨테이너+bastion 양쪽에 키 등록 (4-2, 4-3 반복):**

```bash
# gpu-old2에서
sudo /opt/mlops/teamctl-xfs.sh add-key team23 --key "ssh-ed25519 AAAA... bastion-poc/jangmin"

PORT=22043
echo "permitopen=\"127.0.0.1:${PORT}\" ssh-ed25519 AAAA... bastion-poc/jangmin" \
  | sudo tee -a /home/jump/.ssh/authorized_keys
```

(gpu-old2 쪽도 §3과 동일한 `Match User jump` 블록을 `/etc/ssh/sshd_config.d/jump.conf`에 두는 것을 잊지 말 것.)

**학생 측 `~/.ssh/config` 추가:**

```sshconfig
Host bastion-gpu-old2
    HostName 210.125.91.??       # gpu-old2의 IP로 치환
    Port 22
    User jump
    IdentityFile ~/.ssh/id_ed25519_bastion_poc
    IdentitiesOnly yes

Host team23
    HostName 127.0.0.1
    Port 22043
    User team23
    IdentityFile ~/.ssh/id_ed25519_bastion_poc
    IdentitiesOnly yes
    ProxyJump bastion-gpu-old2
```

**검증 항목:**

- [ ] `ssh team23` 정상 동작 (gpu-old2 bastion 경유 → team23 컨테이너 진입)
- [ ] `ssh team05`도 여전히 정상 (gpu-new bastion 경유)
- [ ] **권한 격리**: gpu-old2 bastion으로는 gpu-new의 team05에 못 닿는지 확인
  ```bash
  ssh -J bastion-gpu-old2 -p 22025 team05@127.0.0.1
  # gpu-old2의 127.0.0.1엔 22025 포트가 없거나, permitopen이 22043만 허용 → 실패
  ```
- [ ] gpu-new가 다운돼도 `ssh team23`은 계속 동작 (장애 격리 확인 — 선택적으로 모니터링 컨테이너 잠시 정지해서 시뮬레이션 가능)

### Step 10. 실제 외부망(VPN 미사용) 시험

- 학교 외부망(예: LTE 테더링)에서 같은 명령으로 접속.
- 방화벽 변경 **전**: 직접 접속도 되고, ProxyJump도 됨.
- 방화벽 변경 **후**: 직접 접속은 안 되고, ProxyJump만 동작 → **최종 검증**.

---

## 7. 통과 기준 체크리스트

- [ ] Step 6: ProxyJump으로 컨테이너 진입 성공 (gpu-new)
- [ ] Step 7-1: bastion 셸 접속 거부 확인
- [ ] Step 7-2: 허용되지 않은 포트 터널 거부 확인
- [ ] Step 8: 로그에서 키 지문으로 학생 식별 가능
- [ ] **Step 9: 다른 서버(gpu-old2)에서 동일 패턴 재현 + 서버 간 권한 격리 성립** ← 본 안의 핵심
- [ ] (외부망 가능 시) Step 10: 외부망에서 ProxyJump 동작
- [ ] VS Code Remote-SSH가 `~/.ssh/config`의 ProxyJump 설정으로 정상 접속

---

## 8. 통과 시 본 매뉴얼 전환에서 손볼 곳

POC가 만족스럽다면 아래 파일/스크립트 수정이 필요합니다 (별도 요청 시 진행):

- **`gpu-servers/teamctl-xfs.sh`** (서버 로컬 작업만, 원격 SSH 호출 없음):
  - `add-key`: 컨테이너 + **같은 서버의** `/home/jump/.ssh/authorized_keys` 양쪽 등록
  - `create`: 신규 팀의 컨테이너 만들 때 bastion 항목 자동 준비
  - `remove`: bastion authorized_keys에서 해당 팀 라인 정리
  - 새 명령 검토: `bastion-list`, `bastion-revoke-key` (서버 로컬)
- **각 서버 초기 셋업 매뉴얼**:
  - `manual/README-initialize-gpu.md`, `README-initialize-gpu-old.md`: `jump` 계정 생성, sshd 설정 추가
  - 호스트 관리자 SSH(루트/우분투)와 bastion jump 계정을 같은 22번 포트에서 `Match User`로 분리할지 결정
- **`manual/README-team.md`**: 학생용 `~/.ssh/config` 안내 (본인 팀이 속한 서버의 bastion 1개만 추가).
- **`manual/README-admin.md`**: **5개 서버**의 bastion 운영 절차 추가 (fail2ban, 로그 회전, 키 회전). 동일 설정을 Ansible/스크립트로 5대에 일괄 배포하는 형태가 자연스러움.
- **모니터링**: 각 서버 bastion의 `auth.log`를 중앙 수집할지 검토 (Promtail/Loki 또는 rsyslog 전송).
- **(장기) SSH CA 검토**: 학생 키를 학과 CA로 서명하고 5대 bastion이 CA만 신뢰. authorized_keys 5곳 동기화 부담을 줄임. POC 단계에서는 보류.

---

## 9. 롤백 절차

POC를 접고 원상복귀하려면 **테스트한 각 서버**에서:

```bash
sudo userdel -r jump
sudo rm -f /etc/ssh/sshd_config.d/jump.conf      # 만들었다면
sudo systemctl reload ssh
```

학생 노트북:

```bash
# ~/.ssh/config의 bastion-* / team*-poc 블록 삭제
rm ~/.ssh/id_ed25519_bastion_poc{,.pub}
```

컨테이너에 등록한 테스트 키 회수:

```bash
# 신규 생성한 팀이라면
sudo /opt/mlops/teamctl-xfs.sh remove team99 --purge-data
# 기존 팀을 재활용했다면 컨테이너 authorized_keys에서 해당 라인만 삭제
```

기존 학생 접속에는 영향 없음 (POC는 별도 키·별도 경로만 사용).
