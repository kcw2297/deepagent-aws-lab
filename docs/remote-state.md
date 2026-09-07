# 원격 state (S3 백엔드)

> 목표: **여러 맥북에서 같은 인프라를 안전하게 다루기.**
> 원래 Day 12 주제였지만, 작업 기기가 여러 대라 앞당겨 적용했습니다.

## state가 뭐길래

Terraform은 `.tf` 코드만 보고 일하지 않습니다. **"내가 지금까지 AWS에 뭘 만들었는지"**
를 기록한 장부가 따로 있는데 그게 state입니다.

`terraform plan`은 이 세 가지를 비교합니다:

```
   코드(.tf)          state             실제 AWS
  "이래야 한다"   "내가 만든 것"      "지금 있는 것"
        └──────────────┴──────────────────┘
                    차이 = plan
```

그래서 state가 없으면 Terraform은 이미 만든 리소스를 **"아직 없네"** 라고 판단해
똑같은 걸 또 만듭니다.

## 왜 git에 올리면 안 되나

state를 git으로 동기화하고 싶은 유혹이 있지만, 세 가지 이유로 안 됩니다.

### 1. 평문 저장소입니다
state에는 리소스의 모든 속성이 그대로 들어갑니다. RDS 비밀번호, IAM 액세스 키,
TLS 개인키가 **암호화 없이 JSON 평문**으로 기록됩니다.
`sensitive = true`는 화면 출력만 가릴 뿐, state 파일 안에는 그대로 있습니다.
한 번 push하면 나중에 지워도 git 히스토리에 영원히 남습니다.

### 2. 병합이 불가능합니다
git은 텍스트를 줄 단위로 합치지만, state는 "실제로 뭐가 존재하는가"에 대한
**단일 사실**입니다. 반반 섞으면 의미가 깨집니다.

```
맥북 A: apply → NAT 생성 → push
맥북 B: (pull 안 함) apply → NAT 또 생성 → 충돌
        → 잘못 병합하면 Terraform이 모르는 NAT가 AWS에 남음
        → destroy해도 안 지워지고 시간당 계속 과금 💸
```

### 3. 잠금장치가 없습니다
두 기기에서 동시에 apply할 때 git은 서로를 막아주지 못합니다.

## 그래서 S3 백엔드

state를 S3에 두고, 어느 기기든 **같은 한 곳**을 읽고 씁니다.

```
   맥북 A ─┐
           ├─→  S3 (state 1개, 잠금 지원)  ─→  AWS 리소스
   맥북 B ─┘
```

설정은 [`terraform/versions.tf`](../terraform/versions.tf)의 `backend "s3"` 블록입니다.

| 항목 | 값 | 이유 |
|------|-----|------|
| `bucket` | `deepagent-eks-tfstate` | 버킷 이름은 **전 세계 모든 AWS 계정을 통틀어 유일**해야 합니다. 이 이름은 비어 있어 그대로 썼습니다 |
| `key` | `eks-lab/terraform.tfstate` | 버킷 안에서의 경로. 나중에 dev/prod를 나누면 여기를 다르게 줍니다 |
| `encrypt` | `true` | 전송·저장 시 암호화 |
| `use_lockfile` | `true` | 동시 실행 방지 잠금 |

### use_lockfile — DynamoDB는 이제 필요 없습니다
예전 자료들은 전부 "S3 + DynamoDB"라고 합니다. 락을 걸 곳이 S3에 없어서
DynamoDB 테이블을 따로 만들어 썼기 때문입니다.
**Terraform 1.11부터 S3 자체 락이 정식 지원**되어, `use_lockfile = true` 한 줄이면
끝입니다. (내부적으로 S3에 `.tflock` 파일을 만들어 구현) 그래서 이 랩에는
DynamoDB 테이블이 없습니다.

### 버킷에 적용된 안전장치
버킷은 `aws` CLI로 1회 생성했고, 다음이 켜져 있습니다.

- **버전 관리** — state를 실수로 망가뜨려도 이전 버전으로 되돌릴 수 있습니다. 가장 중요한 안전장치.
- **기본 암호화(SSE-S3)** — 평문 저장 문제 완화
- **퍼블릭 액세스 전면 차단**
- **라이프사이클** — 30일 지난 이전 버전 자동 삭제 (비용 위생)

### 왜 버킷은 Terraform으로 안 만들었나
**닭과 달걀** 문제입니다. `terraform init`이 백엔드에 연결하려면 버킷이 이미
존재해야 하는데, 그 버킷을 Terraform으로 만들려면 state가 필요합니다.
그리고 애초에 **버킷은 destroy 대상이 아닙니다** — state를 담는 그릇이
state와 함께 사라지면 안 되니까요. 그래서 Terraform 바깥에 둡니다.

## 새 맥북에서 시작할 때

기기마다 딱 두 가지만 하면 됩니다.

```bash
# 1) AWS 자격증명 (기기당 1회)
aws configure          # region: ap-northeast-2, output: json
aws sts get-caller-identity   # 확인

# 2) 백엔드 연결 (리포 클론 후 1회)
cd terraform
terraform init
```

이후엔 어느 기기든 `terraform plan/apply/destroy`가 **같은 state**를 봅니다.
git으로 state를 주고받을 일은 없습니다. (`.gitignore`가 `*.tfstate`를 계속 막고 있습니다)

## 달라진 매일 루틴

```bash
cd terraform
terraform apply      # S3의 state를 읽고 → 잠금 → 생성 → state 갱신 → 잠금 해제
# ... 오늘의 학습 ...
terraform destroy    # 리소스 정리 (버킷은 남습니다)
```

destroy 후 state는 "리소스 0개"인 상태로 S3에 남습니다. 이게 정상입니다.

## 비용

state 파일은 수십 KB라 S3 요금은 **월 1센트 미만**입니다.
매일 destroy하는 원칙과 충돌하지 않습니다.

## 관찰 포인트

1. `terraform apply` 도중 다른 터미널에서 `terraform plan`을 실행하면 어떻게 되나요? (락 확인)
2. S3 콘솔에서 `eks-lab/terraform.tfstate`를 열어보세요. 안에 무엇이 들어 있나요?
3. `destroy` 후 state 파일의 `resources` 배열은 어떻게 변하나요?
4. 버킷의 "버전" 탭에서 state가 apply/destroy마다 쌓이는 걸 확인해 보세요.

## 문제가 생기면

**`Error acquiring the state lock`**
비정상 종료로 락이 남은 경우입니다. 다른 곳에서 정말 실행 중이 아닌지 확인 후:
```bash
terraform force-unlock <LOCK_ID>
```

**state가 꼬였을 때**
S3 버킷의 **버전 관리** 탭에서 직전 정상 버전을 복원하면 됩니다.
버전 관리를 켜둔 이유가 바로 이겁니다.
