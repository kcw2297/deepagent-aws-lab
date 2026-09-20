# Day 12 — 리팩터링: 모듈화 & 환경 분리

> 목표: Day 1~11에 **펼쳐놓은** 코드를 모듈로 묶고, dev/prod 환경을 분리한다.
> 마지막 날에 하는 이유가 있습니다. 반복을 **직접 겪은 뒤에** 묶어야
> "무엇을 입력으로 빼야 하는지"를 알 수 있습니다.

## 모듈이란

특별한 문법이 아닙니다. **`.tf` 파일이 든 디렉터리**를 다른 곳에서 불러 쓰면 그게 모듈입니다.
Day 11까지 써온 `terraform/` 디렉터리도 이미 **루트 모듈**이었습니다.

| 프로그래밍 | Terraform |
|---|---|
| 함수 | 모듈 (디렉터리) |
| 매개변수 | `variables.tf` — 입력 |
| 반환값 | `outputs.tf` — 출력 |
| 함수 호출 | `module "이름" { source = "경로" }` |
| 지역 변수 | 모듈 안 리소스 — **밖에서 못 봄** |

마지막 줄이 핵심입니다. **모듈 안의 리소스는 output으로 내보낸 것만 밖에서 쓸 수 있습니다.**

## 오늘의 구조

```
terraform/
  modules/
    network/            Day 1        VPC · 서브넷 · NAT · 라우팅
    cluster/            Day 2~4,7,11 컨트롤플레인 · 노드그룹 · 접근제어 · OIDC · CP로그
    platform/           Day 6~11     애드온 · 컨트롤러 권한 · 스토리지 · 오토스케일링 · 관측성
      └─ uses ─► pod-identity-role/  (재사용 모듈, 4번 호출)
  envs/
    dev/    main.tf + tfvars + 백엔드 key eks-lab/dev/terraform.tfstate
    prod/   같은 모듈, 다른 값 + 백엔드 key eks-lab/prod/terraform.tfstate

  의존 방향:  network ──► cluster ──► platform   (한쪽으로만)
```

루트(`envs/*`)는 **리소스를 만들지 않습니다.** 모듈을 부르고 값을 넘기고 이어붙일 뿐입니다.

## 핵심 개념

### 1. 모듈 경계는 숨은 결합을 드러낸다 — 순환 참조

파일을 옮기자마자 **순환**이 하나 튀어나왔습니다.

```
Day 11에 만든 것:
  aws_eks_cluster.this   depends_on  aws_cloudwatch_log_group.eks_cluster
  (클러스터가 로그 그룹을 먼저 만들게 해서 "무기한 보관 고아 그룹"을 막았음)

모듈로 나누면:
  cluster 모듈 ──depends_on──► platform 모듈 (로그 그룹이 거기 있으니까)
  platform 모듈 ──cluster_name──► cluster 모듈
  → 순환. Terraform이 거부합니다.
```

한 디렉터리 안에 있을 땐 보이지 않던 의존 방향이, 모듈 경계를 그으니 **컴파일되지 않는 형태로** 드러난 것입니다.

해결은 코드 수정이 아니라 **경계를 다시 긋는 것**이었습니다. 컨트롤플레인 로그 그룹은 이름부터 `/aws/eks/<클러스터>/cluster`이고 클러스터가 켜고 끕니다 — 클러스터의 일부입니다. `modules/cluster/logs.tf`로 옮겼습니다. Container Insights 로그 그룹(에이전트가 쓰는 것)은 platform에 남았습니다.

> **모듈 경계를 잘 그었는지 보는 방법**: 의존이 한 방향으로만 흐르는가.
> 양방향이 필요하다면 경계가 틀린 것입니다.

### 2. 순환을 피하는 또 하나 — 이름은 루트에서 정한다

서브넷에는 `kubernetes.io/cluster/<클러스터이름>` 태그가 필요합니다(Day 1, Day 8 ALB). 그런데 서브넷은 network 모듈, 클러스터는 cluster 모듈입니다.

```
❌ network가 module.cluster.cluster_name 을 받으면  → cluster를 먼저 만들어야 함 → 순환
✅ 이름은 계산이 필요 없다 → 루트에서 정해 양쪽에 넘긴다
```

```hcl
# envs/dev/main.tf
locals {
  cluster_name = "${var.project}-cluster"
}

module "network" { cluster_name = local.cluster_name ... }
module "cluster"  { cluster_name = local.cluster_name ... }
```

**"값이 아직 없어서 못 넘기는 것"과 "그냥 정해두면 되는 것"을 구분**하면 의존이 줄어듭니다.

### 3. 반복을 겪은 뒤에 뽑은 재사용 모듈

Day 8~11에서 컨트롤러를 추가할 때마다 같은 세 덩어리를 썼습니다.

| Day | 컨트롤러 | 권한 방식 | 연결(association) |
|---|---|---|---|
| 8 | LB Controller | 직접 만든 정책 | 모듈이 만듦 |
| 9 | EBS CSI | 관리형 정책 ARN | **애드온이 만듦** |
| 10 | Cluster Autoscaler | 인라인 정책(태그 조건) | 모듈이 만듦 |
| 11 | CloudWatch Agent | 관리형 정책 ARN | **애드온이 만듦** |

그래서 `modules/pod-identity-role`의 입력은 이렇게 정해졌습니다.

```hcl
module "cloudwatch_agent_role" {
  source = "../pod-identity-role"

  project      = var.project
  name         = "cloudwatch-agent"
  cluster_name = var.cluster_name

  namespace          = "amazon-cloudwatch"
  service_account    = "cloudwatch-agent"
  create_association = false      # ← 애드온이 직접 연결하므로 끔

  managed_policy_arns = { cloudwatch-agent = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy" }
}
```

**처음부터 모듈로 만들었다면** 연결 방식이 두 가지라는 것도, 권한 방식이 세 가지라는 것도 몰랐을 겁니다. `create_association`과 `inline_policy` 같은 입력은 **네 번 써본 결과**입니다.

> Day 7의 IRSA/Pod Identity **데모 역할은 일부러 모듈로 바꾸지 않았습니다.**
> 원형(raw 리소스 3개)을 그대로 두어야 모듈이 무엇을 감췄는지 비교할 수 있습니다.

### 4. `for_each`에 list를 쓰면 plan이 깨진다 — 실제로 겪은 에러

처음엔 정책 목록을 `list(string)`으로 받고 `toset()`을 씌웠습니다. plan이 거부했습니다.

```
Error: Invalid for_each argument
  The "for_each" set includes values derived from resource attributes that
  cannot be determined until apply
```

Day 8 LB Controller의 정책은 **우리가 만드는** `aws_iam_policy`라서 ARN이 apply 전에는 미정입니다.

```hcl
❌ for_each = toset([aws_iam_policy.x.arn])   # set은 "값이 곧 키" → 키가 미정
✅ for_each = { alb-controller = aws_iam_policy.x.arn }   # 키는 고정, 값만 미정
```

Terraform은 plan 시점에 **몇 개의 무엇이 생길지** 알아야 합니다. `count`와 `for_each`의 키는 그래서 미정이면 안 됩니다. 입력 타입을 `map(string)`으로 바꿔 해결했습니다.

| | 키 | 목록 중간이 바뀌면 |
|---|---|---|
| `count` | 인덱스(0,1,2…) | 뒤의 리소스가 전부 밀려 **재생성** |
| `for_each` + set | 값 그 자체 | 안전하지만 **값이 미정이면 실패** |
| `for_each` + map | 코드에 적은 키 | 안전하고 미정 값도 OK |

### 5. 모듈에도 `depends_on`을 걸 수 있다

모듈화 전에는 애드온마다 `depends_on = [aws_eks_node_group.this]`를 달았습니다. 이제 platform 모듈은 노드 그룹 리소스를 **알지 못합니다**(다른 모듈 안에 있으니까).

```hcl
module "platform" {
  source = "../../modules/platform"
  ...
  depends_on = [module.cluster]   # 모듈 전체가 cluster 모듈을 기다림
}
```

개별 리소스 이름을 몰라도 되는 것이 오히려 이득입니다. cluster 모듈 안에서 노드 그룹 리소스 이름을 바꿔도 platform은 영향받지 않습니다.

### 6. 환경 분리 — 디렉터리(백엔드 key) vs workspace

이번엔 **디렉터리 분리**를 택했습니다.

```
envs/dev/versions.tf    key = "eks-lab/dev/terraform.tfstate"
envs/prod/versions.tf   key = "eks-lab/prod/terraform.tfstate"
```

| | 디렉터리 분리 (선택) | workspace |
|---|---|---|
| state | key가 달라 완전 분리 | 한 백엔드 안에서 접두사로 분리 |
| 환경별 차이 | **tfvars뿐 아니라 구조도** 다르게 가능 | 코드가 하나라 `terraform.workspace` 분기가 늘어남 |
| 실수 위험 | 디렉터리가 곧 환경 | **현재 workspace를 착각**하면 prod에 apply |
| 인증 분리 | 환경별 계정/프로파일을 다르게 두기 쉬움 | 한 설정을 공유 |
| 비용 | 파일이 두 배 | 파일은 하나 |

workspace는 "완전히 같은 구조를 잠깐 복제"할 때(예: 리뷰용 임시 환경) 적합하고, **오래 가는 dev/prod에는 디렉터리 분리가 일반적**입니다. 실수로 prod에 apply하는 사고가 workspace에서 훨씬 쉽게 납니다.

디렉터리 분리의 대가는 **중복**입니다. `main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`가 환경마다 있고, 모듈에 입력을 추가하면 양쪽을 고쳐야 합니다. 이 중복을 줄이려고 Terragrunt 같은 도구를 쓰기도 합니다.

### 7. 리팩터링이 안전했는지 확인하는 법

주소가 바뀌는 작업이라 **"같은 것이 만들어지는가"**를 확인해야 합니다.

```bash
# 리팩터링 전 코드를 임시 워크트리에 꺼내 plan
git worktree add /tmp/oldtf HEAD
cd /tmp/oldtf/terraform && terraform init -backend=false && terraform plan
→ Plan: 54 to add

# 리팩터링 후
make plan ENV=dev
→ Plan: 54 to add        ✅ 같음

git worktree remove --force /tmp/oldtf
```

`terraform init -backend=false`는 **S3 백엔드에 연결하지 않고** 코드만 검사합니다. 원격 state를 건드리지 않으므로 비교용으로 안전합니다.

### 8. 리소스가 살아 있었다면 — `moved` / `state mv`

이번에는 **destroy 직후 state가 비어 있어서** 그냥 새 구조로 apply하면 됐습니다. 운영 중이었다면 이야기가 다릅니다.

```
aws_eks_cluster.this  →  module.cluster.aws_eks_cluster.this
Terraform은 "옛 주소 삭제 + 새 주소 생성"으로 읽습니다 → 클러스터 재생성 💥
```

막는 방법 두 가지입니다.

```hcl
# ① moved 블록 — 코드에 남아 리뷰·협업에 유리 (권장)
moved {
  from = aws_eks_cluster.this
  to   = module.cluster.aws_eks_cluster.this
}
```

```bash
# ② state mv — 명령으로 즉시 이동. 기록이 코드에 안 남음
terraform state mv aws_eks_cluster.this module.cluster.aws_eks_cluster.this
```

어느 쪽이든 **plan에 "0 to destroy"가 뜨는지** 반드시 확인하고 apply해야 합니다.

## 오늘 만든 것

| 위치 | 내용 |
|---|---|
| `terraform/modules/network/` | Day 1 네트워크. 입력 6개, 출력 4개 |
| `terraform/modules/cluster/` | 컨트롤플레인·노드그룹·접근제어 + OIDC(irsa에서 이동) + CP 로그(observability에서 이동) |
| `terraform/modules/platform/` | 애드온·LBC·스토리지·오토스케일링·관측성. 역할 4개는 재사용 모듈 호출로 |
| `terraform/modules/pod-identity-role/` | **재사용 모듈** — 역할 + 권한(관리형/인라인) + 연결(선택) |
| `terraform/envs/dev/` | 루트 모듈. 백엔드 key `eks-lab/dev/...` |
| `terraform/envs/prod/` | 같은 모듈, 다른 값. **apply하지 않습니다** |
| `Makefile` | `ENV` 변수 추가 (`make plan ENV=prod`) |
| `CLAUDE.md` | 새 디렉터리 구조와 규칙 반영 |

## 실습 순서

```bash
# 1) 구조 검증 (AWS를 건드리지 않음)
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/envs/prod validate

# 2) 백엔드 초기화 — key가 바뀌었으므로 환경마다 1회
make init ENV=dev
make init ENV=prod

# 3) 리팩터링 전후 비교 (위 7번)

# 4) 같은 모듈이 다른 값으로 어떻게 그려지는지
make plan ENV=prod     # 노드 t4g.large 3대, 로그 30일 보관, VPC 10.10.0.0/16

# 5) 실제로 세워보기
make apply ENV=dev
```

## 실습 결과

| 항목 | 리팩터링 전 | 후 |
|---|---|---|
| `.tf` 파일 | `terraform/` 아래 14개 | 모듈 4개 + 환경 2개로 분산 |
| 리소스 블록 | 47개 | 41개 (역할 4벌 → 재사용 모듈 1벌) |
| **plan 생성 수** | **54** | **54** ✅ |
| prod plan | — | 54 (같은 모듈, 다른 값) |

## 관찰 포인트

1. 컨트롤플레인 로그 그룹을 platform에 둔 채로 모듈화하면 어떤 에러가 나나?
2. 클러스터 이름을 cluster 모듈의 output으로 network에 넘기면 왜 안 되나?
3. `for_each`에 list를 쓰면 어떤 경우에만 실패하나? 왜 map은 되나?
4. platform 모듈에서 `aws_eks_node_group.this`를 참조할 수 없는 이유는?
5. 리소스가 살아 있는 상태에서 모듈화했다면 무엇을 먼저 했어야 하나?
6. workspace 대신 디렉터리 분리를 택한 이유는?

## 비용 메모

- **오늘 작업 자체는 $0** — 코드 재배치와 plan(읽기 전용)뿐입니다
- `envs/prod`는 **plan까지만** 합니다. apply하면 dev와 별개의 클러스터가 하나 더 생겨 시간당 비용이 두 배가 됩니다
- `make apply`의 기본값은 `ENV=dev`입니다. prod는 항상 명시해야 하므로 실수로 세워지지 않습니다

## 부록 — destroy를 끝까지 기다려야 하는 이유

Day 12 시작 전 확인해 보니, 전날 `make destroy`가 **중간에 끊겨** 클러스터가 16.5시간 살아 있었습니다(약 $1.65).

```
19:42  잠금(.tflock) 생성, 노드그룹·애드온·NAT·EIP 삭제
       ❌ 클러스터 삭제 전에 프로세스 종료
다음날  클러스터 ACTIVE, S3에 잠금 파일만 남음 → 다음 실행이 막힘
```

```bash
# 다른 기기에서 실행 중이 아님을 확인한 뒤
terraform -chdir=terraform/envs/dev force-unlock <LOCK_ID>
make destroy
```

잠금 해제는 Terraform이 **정상 종료할 때** 합니다. 그래서 `make destroy`에 "끝까지 기다리라"는 안내를 추가했습니다. 세션을 마칠 때는 남은 리소스를 눈으로 확인하는 습관이 안전합니다.

```bash
aws eks list-clusters --region ap-northeast-2 --query clusters --output text
aws ec2 describe-nat-gateways --region ap-northeast-2 \
  --filter Name=state,Values=available,pending --query "NatGateways[].NatGatewayId" --output text
```

## 다음

커리큘럼의 12일이 끝났습니다. 이후는 `docs/curriculum.md`의 **심화 주제**에서 고르면 됩니다.
Day 12의 결과로 이제 새 구성 요소를 추가할 자리가 분명합니다 — 리소스는 `modules/` 안에, 값은 환경의 tfvars에.
