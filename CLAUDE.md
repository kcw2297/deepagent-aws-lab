# deepagent-aws-lab — 작업 규칙

AWS EKS를 **한 계층씩 직접 만들어 보며** 배우는 학습용 리포입니다.
아래 규칙은 코드만 봐서는 알 수 없는 것들이라, 작업 전에 반드시 확인하세요.

## 이 리포의 목적은 "동작하는 인프라"가 아니라 "이해"입니다

- **커뮤니티 모듈을 쓰지 마세요.** `terraform-aws-modules/*` 같은 걸로 감싸면
  코드는 짧아지지만 학습 목적이 사라집니다. 리소스를 하나씩 직접 작성합니다.
- **추상화/DRY를 위한 리팩터링을 먼저 제안하지 마세요.** 반복이 보여도
  눈에 보이는 게 우선입니다. 모듈화는 Day 12의 주제입니다.
- **주석은 "무엇"이 아니라 "왜"를 한국어 학습 노트 톤으로** 씁니다.
  기존 `terraform/*.tf`의 주석 밀도와 스타일을 그대로 따라가세요.
  일반적인 프로덕션 코드보다 주석이 훨씬 많은 게 의도된 것입니다.

## 매일 껐다 켭니다 (비용)

- 세션 시작 `terraform apply` → 학습 → 세션 끝 **`terraform destroy`**.
- 비용의 대부분이 시간당 과금입니다: NAT 게이트웨이(~$0.045/h),
  이후 추가될 EKS 컨트롤플레인($0.10/h), 워커 노드.
- 그래서 **비용을 늘리는 리소스를 임의로 추가하지 마세요.** 필요하면 먼저 말하세요.
  (예: NAT는 학습용이라 AZ마다가 아닌 1개만 둡니다 — 의도된 선택입니다.)

## 계층은 위로만 쌓습니다

- `docs/curriculum.md`의 Day 순서를 따릅니다. 앞 Day를 건너뛰고 뒤를 먼저 만들지 마세요.
- 각 Day마다 `docs/day-XX-<주제>.md` 학습 노트를 함께 작성합니다.
  (구조: 왜 이걸 하는지 → 다이어그램 → 핵심 개념 표 → 실습 명령 → 관찰 포인트 → 비용 메모)

## 진행 상황은 `docs/curriculum.md`에만 기록합니다

- Day 완료/진행 표시는 **`docs/curriculum.md` 한 곳에서만** 갱신하세요.
  표기: `✅` 완료 · `🟢 (현재)` 진행 중 · 표시 없음 = 예정
- **README.md에는 진행 상황을 적지 않습니다.** 두 곳에 두면 반드시 어긋납니다.

## 맥북 2대에서 작업합니다

- 같은 리포를 **맥북 2대**에서 번갈아 씁니다. 그래서 state가 로컬에 있으면 안 됩니다.
- state는 **S3 원격 백엔드** (`deepagent-eks-tfstate`, ap-northeast-2)에 있고
  `use_lockfile = true`로 동시 실행을 막습니다. 자세히: `docs/remote-state.md`
- 새 기기에서는 `aws configure` → `terraform init` 두 단계가 필요합니다.
- **state 파일을 git에 올리지 마세요.** 평문 비밀정보가 들어 있고 병합이 불가능합니다.
- **state 버킷은 Terraform 관리 대상이 아닙니다.** `destroy`로 지워지면 안 되므로
  의도적으로 코드 바깥(aws CLI로 1회 생성)에 둡니다. `.tf`에 버킷 리소스를 추가하지 마세요.

## 코드 작업 흐름

리포 루트의 `Makefile`을 씁니다. (`make` = 사용법, `make init/plan/apply/destroy`)

```bash
make plan                      # apply 전에 무엇이 왜 생기는지 읽기
terraform -chdir=terraform fmt      # 커밋 전 항상
terraform -chdir=terraform validate
```

`.tf` 파일을 수정했으면 커밋 전에 `fmt`와 `validate`를 돌리세요.

- 변수는 `variables.tf`에 정의하고 값은 `terraform.tfvars`에 명시합니다 (default가 있어도).
- 리전은 `ap-northeast-2`(서울), AZ는 `2a`/`2c` 2개만 씁니다.
- 리소스 이름/태그 접두사는 `var.project`를 씁니다. 공통 태그는 provider의 `default_tags`가 붙입니다.
