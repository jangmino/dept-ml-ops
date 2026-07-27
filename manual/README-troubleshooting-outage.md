# 서버 다운 대응 체크리스트 (서버실 현장용)

> 대상: gpu-new(210.125.91.95) 전면 무응답 장애 — 2026-07-27 발생
> 증상: ICMP 100% loss, 22/80/443 전부 무응답. 구서버 4대 + 스토리지는 정상.
> 조교용 현장 절차는 [README-onsite-assistant.md](README-onsite-assistant.md) 참조.

---

## 사전 원격 진단 결과 (2026-07-27, 서버실 방문 전)

### 확인된 사실

| 서버 | IP | ICMP | SSH:22 |
|------|-----|:----:|:------:|
| gpu-old1 | .90 | ✅ | ✅ `SSH-2.0-OpenSSH_9.6p1` |
| gpu-old2 | .91 | ✅ | ✅ |
| gpu-old3 | .92 | ✅ | — |
| gpu-old4 | .93 | ✅ | — |
| storage | .94 | ✅ | ✅ |
| **gpu-new** | **.95** | **❌ 100% loss** | **❌ 무응답** |

- `.95`의 22 / 80 / 443 / 9090 / 9093 **전부 무응답**, SSH 배너도 없음
- **ICMP unreachable이 아니라 순수 timeout** → 능동적 거부가 아닌 블랙홀
- 학내 사용자(team01 등) **다수가 제보** → 특정 출발지 IP만 밴된 경우는 배제
- 보안팀 **통보 메일 없음** (확인함)
- ⚠️ `22021` 포트가 막힌 것은 **정상**이다 (`ufw deny 22021:22069/tcp`). 진단 근거로 쓰지 말 것
- 구서버와는 별도 내부망이 없어 원격 우회 진단 경로 없음. 스위치도 관리 IP 미부여

### 가설 순위 (현장에서 위에서부터 배제)

| # | 가설 | 판별 방법 | 근거 |
|---|------|----------|------|
| 1 | **랜케이블 / 스위치 포트 불량** | 스위치 링크업 포트 수(정상 7개), 서버 NIC LED | 스위치 1대에 6대가 물렸는데 1대만 침묵. 랙에서 흔한 고장이고 복구도 가장 쉬움 |
| 2 | **전원 / 하드웨어 장애** | 전원 LED, BMC 접속 가능 여부 | 랙 PDU는 정상(다른 5대 가동 중) → 개별 PSU·전원케이블·PDU 포트 |
| 3 | **OS 다운** (커널 패닉·행) | 전원 켜짐 + 콘솔 무응답/패닉 화면 | 원격으로는 2번과 구분 불가 |
| 4 | **학교 보안팀 IP 차단** | 콘솔에서 아웃바운드는 되는데 인바운드만 죽음 + 로컬 ufw 정상 | GPU 서버는 채굴 표적. [team03 cloudflared 전례](README-team.md) 있음. 단 **통보가 없었던 점이 감점** |
| 5 | **로컬 방화벽 자충수** | `ufw status verbose` | 최근 커밋에 해당 작업 없음 → 가능성 낮음 |

> **핵심 분기점은 서버 NIC LED 하나다.** 꺼져 있으면 1번, 켜져 있으면 2~5번으로 갈린다.

---

## 0. 출발 전 준비

### 챙길 것
- [ ] **모니터 + USB 키보드** (또는 크래시카트) — 서버 후면 출력 단자 확인 필요(보통 VGA)
- [ ] **랜 케이블 여분 1~2개** — 케이블 불량 배제용
- [ ] **노트북** + USB-C 이더넷 어댑터 — 스위치 포트에 직결해 링크 확인
- [ ] **USB 부팅 디스크**(Ubuntu Live) — 최악의 경우 복구 셸
- [ ] 폰(이 문서 열람 + 화면 촬영), 손전등
- [ ] 랙 키

### 미리 확인해둘 것
- [ ] gpu-new 랙 위치 / PDU 어느 포트에 물려 있는지
- [ ] team01~ 사용자에게 "내일 오전 점검 예정" 공지

### BMC(IPMI) — 1순위 진단 경로

서버가 꺼져 있어도 **AC만 들어오면 붙는다.** OS가 죽어도 콘솔 진입·전원 제어가 가능하다.
반대로 **BMC조차 응답이 없으면 AC 자체가 안 들어온다는 뜻**이므로, 그 실패도 중요한 정보다.

| 서버 | BMC IP | 비고 |
|------|--------|------|
| gpu-new | `<BMC-IP-GPU-NEW>` | **확인됨** |
| storage | `<BMC-IP-STORAGE>` | 미검증 |
| gpu-old1~4 | ? | **이번에 확인해서 채울 것** |

- 접속: 노트북을 서버 뒷면 `M` 포트에 **직결** → 노트북에 `<관리망 미사용 IP>/24` 수동 설정
  (**게이트웨이 비움** — 비워야 Wi-Fi 인터넷이 유지된다) → 브라우저로 BMC IP 접속
- 계정·비밀번호: **리포지토리 외부에서 관리** (`manual/*.local.md`는 gitignore 처리됨)
- 조교에게 맡길 경우 단계별 절차: [README-onsite-assistant.md](README-onsite-assistant.md)

> 🔒 이 리포지토리는 **공개**다. BMC 주소·계정·비밀번호는 절대 커밋하지 말 것.
> 실값은 `manual/README-onsite-assistant.local.md`(로컬 전용)에 있다.

### 참고: 랙 네트워크 구성 (2026-07 현재)

```
        [학교망]
            │  (RJ45 업링크 1가닥 — SFP+ 17/18은 미사용)
    ┌───────┴────────────────────────┐
    │  NETGEAR XS516TM (랙 최상단)    │  16×10G RJ45 + 2×SFP+
    │  ⚠️ 관리 IP 미부여 → 원격 진단 불가 │  스마트 매니지드
    └─┬──┬──┬──┬──┬──┬───────────────┘
      │  │  │  │  │  │
   gpu-new  old1 old2 old3 old4  storage      ← 서버당 데이터 포트 1가닥
   (.95)   (.90)(.91)(.92)(.93)  (.94)

   * 정상 시 링크 업 포트 = 7개 (서버 6 + 업링크 1)
   * 각 서버의 두 번째 데이터 포트, BMC(M) 포트는 모두 미결선
   * ⚠️ 이 스위치 1대가 전 서버 + 업링크를 모두 수용 — 단일 장애점
```

> **진단 시사점:** 6대 중 1대만 죽었다면 스위치 자체는 정상이고, **해당 포트 또는 케이블**이 후보다.
> 스위치 포트 LED 개수를 세는 것만으로 서버 문제 / 배선 문제가 갈린다.

### 참고: gpu-new 정상 설정값
| 항목 | 값 |
|------|-----|
| eth0 | `210.125.91.95/24` |
| default gw | `210.125.91.1` |
| DNS | `210.125.88.1`, `8.8.8.8` |
| eth1 | dhcp4 (용도 확인 필요) |
| ufw | 22/tcp allow, 80/tcp allow, 22021~22069/tcp **deny** |

---

## 1. 도착 즉시 — 30초 육안 판정

- [ ] gpu-new **전원 LED** — 켜짐 / 꺼짐 / 점멸(경고)
- [ ] **팬 소리** 나는가
- [ ] **NIC 링크 LED** — 서버 후면 + 스위치 쪽 포트 양쪽 다
- [ ] **PSU LED** 색상 (녹색 정상 / 주황·적색 이상)
- [ ] 옆 구서버들 정상 동작 확인 (대조군 — 랙 전원 자체는 살아있음이 이미 확인됨)
- [ ] **탄내 확인** → 나면 전원 넣지 말고 중단

→ 전원 꺼짐이면 **[분기 A]**, 켜져 있으면 **[분기 B]**

---

## 2. [분기 A] 전원이 꺼져 있는 경우

### ⚠️ 바로 전원 버튼 누르지 말 것. 먼저 관찰.

**A-1. AC가 들어오고 있는지 판별 (가장 중요)**

BMC는 대기전원으로 동작하므로, AC가 살아 있으면 OS가 꺼져 있어도 BMC/대기 LED는 켜져 있다.

| BMC·대기 LED | 판정 | 다음 |
|---|---|---|
| 켜짐 | AC 정상. OS가 꺼졌거나 셧다운/패닉 후 정지 | A-3으로 |
| 꺼짐 | **AC 자체가 안 들어옴** | A-2로 |

**A-2. AC 미공급일 때**
- [ ] 전원 케이블 양끝(서버·PDU) 체결 확인, 한 번 뽑았다 다시 꽂기
- [ ] PDU 해당 포트 차단기/LED 확인
- [ ] **옆 정상 서버 콘센트와 교체 테스트** → 살아나면 PDU 포트 불량 확정
- [ ] 이중화 PSU면 두 번째 PSU도 케이블 확인 (한쪽만 죽었을 수 있음)
- [ ] 그래도 안 되면 PSU 고장 → 예비 PSU 교체

**A-3. 전원 투입**
- [ ] 모니터·키보드 먼저 연결 (POST를 놓치지 않기 위해)
- [ ] 전원 버튼 → POST 화면 관찰, **이상 메시지는 폰으로 촬영**
- [ ] 비프음 패턴 / POST 코드 LED 기록
- [ ] 부팅 성공 → **[분기 C]**
- [ ] 부팅 실패 → A-4

**A-4. 부팅 실패 시**
- [ ] BIOS 진입 → **BMC 이벤트 로그 확인** (전원 이상/온도/하드웨어 에러 기록)
- [ ] BIOS에서 디스크·메모리·GPU 인식 개수 확인
- [ ] **`Restore on AC Power Loss` = Power On 으로 설정** (정전 후 자동 복구되도록)
- [ ] **BMC IP 확인해서 기록** ← 필수
- [ ] 메모리/GPU 재장착 시도

---

## 3. [분기 B] 전원이 켜져 있는 경우

- [ ] 모니터·키보드 연결 (크래시카트)

| 화면 상태 | 판정 | 조치 |
|---|---|---|
| 커널 패닉 / OOM / XFS·파일시스템 에러 | OS 크래시 | **촬영 필수** → 재부팅 → 분기 C |
| 검은 화면, 키 입력 무반응 | 하드 행(hang) | 촬영 → 강제 재부팅 → 분기 C |
| 로그인 프롬프트 정상 | **OS는 살아있고 네트워크만 죽음** | 재부팅하지 말고 바로 **분기 C** |

- [ ] NIC 링크 LED가 꺼져 있으면: 케이블 교체 → 스위치 다른 포트로 이설 → 그래도 안 되면 NIC 문제
- [ ] ⚠️ 로그인 프롬프트가 살아있으면 **재부팅하기 전에 분기 C의 로그 수집을 먼저** 하라. 재부팅하면 증거가 날아간다.

---

## 4. [분기 C] 콘솔 로그인 성공 — 진단

### C-1. 언제부터, 왜 죽었나
```bash
uptime
last reboot | head -5
journalctl --list-boots | tail -5
journalctl -b -1 -p err --no-pager | tail -40    # 직전 부팅의 에러 = 죽은 원인
dmesg -T | tail -50
df -h / /data                                     # 디스크 풀?
free -h
```

### C-2. 네트워크 계층 — **핵심 분기**
```bash
ip -br a                        # eth0에 210.125.91.95/24 있나
ip route                        # default via 210.125.91.1 하나만 있어야 정상
ping -c3 210.125.91.1           # ① 게이트웨이 (L2/스위치)
ping -c3 210.125.91.94          # ② 스토리지 (같은 /24 대조군)
ping -c3 8.8.8.8                # ③ 아웃바운드
curl -s -m5 ifconfig.me; echo   # 나가는 공인 IP
```

**결과 해석표**

| ① gw | ② .94 | ③ 8.8.8.8 | 판정 |
|:---:|:---:|:---:|---|
| ✅ | ✅ | ✅ | 아웃바운드 정상 / **인바운드만 차단 → 상위(보안팀) 차단 유력** |
| ✅ | ✅ | ❌ | 상위에서 양방향 차단 → **보안팀 차단 거의 확실** |
| ✅ | ❌ | ❌ | 게이트웨이까지만. 상위 라우팅/차단 |
| ❌ | ❌ | ❌ | **L2 문제** — NIC·케이블·스위치 포트 |
| IP 자체가 없음 | | | netplan 미적용 / NIC 인식 실패 |

### C-3. 로컬 방화벽 (자책골 배제)
```bash
sudo ufw status verbose                       # 22/tcp, 80/tcp ALLOW 인가
sudo iptables -L INPUT -n --line-numbers | head -30
sudo fail2ban-client status sshd 2>/dev/null  # 밴 목록
```
로컬 룰이 정상인데 인바운드가 죽어 있으면 → **상위 차단 확정**

### C-4. 서비스 상태
```bash
systemctl status ssh docker --no-pager
ss -tlnp | grep -E ':(22|80)\b'
```

### C-5. 침해 흔적 확인 (보안팀 차단이 의심되면 반드시)
```bash
nvidia-smi                                    # 유휴여야 할 GPU가 100%면 채굴 의심
docker ps -a
docker stats --no-stream
sudo ss -tunp | grep ESTAB                    # 이상한 아웃바운드 연결
sudo journalctl -u ssh | grep -i Accepted | tail -50
last -20
docker exec <컨테이너> ps aux --sort=-%cpu | head -20
```
> 2026-07-03 team03 cloudflared 사건 전례가 있다. 터널링·채굴·스캐닝은 보안팀 자동 차단의 대표 트리거다.
> **차단 해제만 요청하지 말고 원인부터 찾을 것.** 원인 그대로면 또 막힌다.

---

## 5. 복구 후 확인 — **반드시 이 순서대로**

컨테이너는 팀·모니터링 모두 `restart: unless-stopped`라 **자동으로 올라온다.**
문제는 "올라왔는가"가 아니라 **"제대로 올라왔는가"** 다. 아래 3개가 조용히 깨지는 지점이다.

### 5-1. NVIDIA 드라이버 ⚠️ 최우선

```bash
uname -r                        # 커널이 바뀌었는지
nvidia-smi                      # GPU 목록이 나오는지
dkms status                     # 현재 커널에 nvidia 모듈이 빌드돼 있는지
```

> **왜 위험한가:** 오래 켜져 있던 서버가 재부팅되면 그동안 unattended-upgrades가 깔아둔
> **새 커널로 부팅**된다. DKMS가 그 커널용 NVIDIA 모듈을 못 만들었으면 `nvidia-smi`가 죽고,
> GPU를 요청하는 **팀 컨테이너 전부 + `mon_dcgm_exporter`가 기동 실패**한다.
> "재부팅했더니 갑자기 GPU가 없다"의 대부분이 이것.
>
> 복구: `sudo apt install --reinstall nvidia-driver-580-server` 후 재부팅,
> 또는 GRUB에서 이전 커널로 부팅.

### 5-2. NFS 마운트 ⚠️ 조용히 깨지는 지점

```bash
mount | grep -E 'nfs|/mnt/nfs'          # 호스트에 실제로 붙었는지
ls /mnt/nfs/teams/                       # 팀 디렉터리가 보이는지
systemctl status mnt-nfs-teams.automount

# ★ 컨테이너 안에서 확인 — 이게 진짜 검사
docker exec team01_gpu0 df -h /nfs/team  # nfs 타입으로 잡혀야 정상
docker exec team01_gpu0 ls /nfs/team
```

> **왜 위험한가:** `/mnt/nfs/teams`는 `x-systemd.automount`(autofs) 마운트포인트다.
> Docker가 automount 트리거 전에 컨테이너를 띄우면 **NFS가 아니라 그 아래 빈 디렉터리가
> 바인드될 수 있다.** 그러면 컨테이너의 `/nfs/team`이 빈 채로 보이고,
> **학생이 쓰는 데이터가 NFS가 아니라 OS 루트 디스크에 쌓인다.** 에러 메시지가 안 난다.
>
> 증상 확인: `df -h /nfs/team`이 `nfs4`가 아니라 로컬 파일시스템으로 나오면 이 경우다.
> 복구: `sudo mount -a` 후 해당 컨테이너만 `docker compose -f /opt/mlops/compose.yaml up -d --force-recreate <team>`

### 5-3. 컨테이너 / 쿼터

```bash
docker ps -a                                    # Exited/Restarting 있는지
cd /opt/mlops && docker compose ps
/opt/mlops/teamctl-xfs.sh audit                 # XFS 쿼터 정상 적용 확인
/opt/mlops/teamctl-xfs.sh list-mounts
mount | grep /data                              # prjquota 옵션 살아있는지
```

> **자동 복구 안 되는 경우 2가지:**
> 1. `teamctl-xfs.sh reset TEAM`을 했던 팀 — reset은 컨테이너를 **삭제**하므로
>    (`compose rm -s -f`) 재부팅해도 안 올라온다. → `docker compose -f /opt/mlops/compose.yaml up -d <team>`
> 2. 장애 전에 수동으로 `docker stop` 한 컨테이너 — `unless-stopped`는 수동 정지분을 복구하지 않는다

### 5-4. 모니터링 스택

```bash
cd /opt/monitoring && docker compose ps
curl -s localhost:9090/-/healthy         # Prometheus
curl -s localhost:9093/-/healthy         # AlertManager
curl -sI localhost:80 | head -1          # nginx → Grafana
curl -s 'localhost:9090/api/v1/targets?state=active' | grep -o '"health":"[a-z]*"' | sort | uniq -c
```
데이터(Prometheus TSDB, Grafana 대시보드·비밀번호)는 named volume이라 **그대로 보존**된다.

### 5-5. 마무리

- [ ] 외부에서 `ping 210.125.91.95`, `ssh miruware@210.125.91.95` 재확인
- [ ] **Grafana 그래프의 공백 구간 = 실제 다운 시각.** 단, Prometheus가 gpu-new에 있으므로
      이 구간은 **전 서버 데이터가 비어 있다** (구서버가 죽은 게 아니다)
- [ ] team01~ 사용자에게 복구 공지 + `/nfs/team` 데이터 이상 없는지 확인 요청

---

## 6. 사후 조치 (재발 방지)

- [ ] **관리망(BMC) 원격 접근 확보** — 이번 건의 가장 큰 교훈.
      BMC IP는 알고 있었지만 **직결로만 접근 가능**해서 결국 사람이 서버실에 가야 했다.
      BMC가 원격으로 닿았으면 전원 상태 확인·콘솔 진입·전원 제어가 책상에서 끝났다.
      - 방안 A: 각 서버 `M` 포트를 XS516TM에 상시 연결 + 구서버 1대(`eno1`, `100.100.0.0/24`)를
        관리망 점프 호스트로. **단 아래 VLAN 항목이 선행되어야 함**
      - 방안 B: 관리망 전용 소형 장비(라즈베리파이 등)를 두고 SSH 점프
      - ⚠️ 어느 쪽이든 **BMC 인증 강화(계정·비밀번호 점검)가 선행**되어야 한다. 관리망이 넓어지는 만큼 위험도 커진다.
- [ ] 전 서버 BMC IP 표 완성 (0절 「BMC(IPMI) — 1순위 진단 경로」 표)
- [ ] **스위치(XS516TM)에 관리 IP 부여** — 지금은 IP가 없어서 포트 링크 상태조차 원격으로 못 본다.
      IP만 있었으면 이번 건의 "서버 문제 vs 배선 문제"를 책상에서 5분 만에 갈랐다.
      - 포트 링크 상태 / 패킷 카운터 / MAC 테이블 → 원격 1차 진단이 전부 가능해진다
- [ ] **BMC를 이 스위치에 물릴 경우 VLAN 분리 필수** — 이 스위치는 학교망 업링크와 같은 L2다.
      BMC(`100.100.0.x`)를 그냥 꽂으면 학교망 어느 호스트든 자기 IP를 `100.100.0.x`로 바꿔
      BMC에 접근할 수 있다. **BMC는 전원·콘솔·가상미디어 전권** = 서버 완전 장악.
      → ① BMC 인증 강화 ② 스위치에서 BMC 포트를 별도 VLAN으로 분리 ③ 구서버 1대를 점프 호스트로
- [ ] **스위치 단일 장애점** — 이 1대가 죽으면 서버 6대가 동시에 사라진다. 예비 스위치 확보 검토
- [ ] BIOS `Restore on AC Power Loss` = Power On 확인
- [ ] **모니터링 단일 장애점 해소** — Prometheus/Grafana/AlertManager가 전부 gpu-new에 있어서
      gpu-new가 죽으면 알림이 아예 안 나간다. 이번에도 학생 제보로 알았다.
      → 외부 dead-man's-switch(healthchecks.io 등) 또는 gpu-old 중 1대에 최소 감시자 배치
- [ ] 다운 시각·원인·조치 내역 기록
