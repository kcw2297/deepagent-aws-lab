# Day 8 — Gateway API + AWS Load Balancer Controller

> 목표: 앱을 **인터넷에 노출**한다.
> 지금까지 `kubectl port-forward`로만 접근했던 앱에 실제 ALB를 붙입니다.
>
> **Ingress가 아니라 Gateway API로 갑니다.**

## 왜 Ingress가 아닌가

- **Ingress API는 동결(frozen)** 상태입니다. GA지만 신규 기능이 들어가지 않습니다.
- **AWS Load Balancer Controller가 2026년 초 Gateway API GA 지원**을 발표했습니다 (LBC v3.4.0~).
- **NGINX Ingress Controller가 2026 Q1 EOL** — 마이그레이션 수요의 배경입니다.

Ingress의 근본 문제는 **설정이 애노테이션 문자열**이라는 점이었습니다.

```yaml
# Ingress 시절
annotations:
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip
  alb.ingress.kubernetes.io/healthcheck-path: /healthz
```

오타가 나도 **런타임까지 모릅니다.** 조용히 무시되고 기본값으로 동작합니다.
Gateway API는 스키마가 있는 리소스라 `kubectl`이 즉시 거부합니다 —
실제로 오늘 그 이점을 봤습니다(아래 "막혔던 지점" 참고).

## 오늘의 구조

```
  [인프라 관리자 영역]
  GatewayClass "alb"  (클러스터 전역)
     controllerName: gateway.k8s.aws/alb
          ↑ 참조
  Gateway "app-gateway"  (demo 네임스페이스)          → 실제 ALB 1대 생성
     gatewayClassName: alb
     listeners: HTTP:80
     allowedRoutes: from Same
     infrastructure.parametersRef → LoadBalancerConfiguration (scheme: internet-facing)
          ↑ 참조
  [앱 개발자 영역]
  HTTPRoute "app-route"  (demo)
     parentRefs: app-gateway
     rules: /healthz → Service, / → Service
```

## 핵심 개념

### 1. GatewayClass vs Gateway — StorageClass : PVC 와 같은 관계

| | **GatewayClass** | **Gateway** |
|---|------------------|-------------|
| 스코프 | **클러스터 전역** (`NAMESPACED=false`) | 네임스페이스 |
| 의미 | "이 종류는 **누가 구현**하나" | "**실제 로드밸런서 한 대**" |
| 개수 | 보통 몇 개 (alb, nlb…) | 필요한 만큼 |
| 핵심 필드 | `controllerName` | `listeners`, `gatewayClassName` |
| AWS 리소스 | ❌ 안 만듦 | ✅ **ALB 생성** |

```
gateway.k8s.aws/alb → ALB (L7, HTTPRoute/GRPCRoute)
gateway.k8s.aws/nlb → NLB (L4, TCPRoute/UDPRoute)
```

### 2. 3계층 역할 분리 — Ingress와의 가장 큰 차이

| 계층 | 담당 | 결정하는 것 |
|------|------|-------------|
| GatewayClass | 인프라 제공자 | "우리는 ALB를 쓴다" — 한 번 설정 |
| **Gateway** | 클러스터 운영자 | 포트·TLS·노출 방식·**누가 붙을 수 있나** |
| **HTTPRoute** | 앱 개발자 | 경로·백엔드 |

Ingress는 이 셋이 한 오브젝트에 섞여, 앱 개발자가 인프라 애노테이션까지 건드려야 했습니다.

Gateway의 `allowedRoutes`가 역할 분리의 핵심입니다:

```yaml
allowedRoutes:
  namespaces:
    from: Same     # 이 Gateway와 같은 네임스페이스의 Route만 허용
```

앱팀이 마음대로 붙이는 게 아니라 **인프라팀이 허용한 범위 안에서만** 붙습니다.
`All` / `Selector`로 열 수 있어, 멀티테넌트에서 "이 Gateway는 team-a-* 만" 같은 정책이 가능합니다.

**방향성도 중요합니다** — Gateway가 Route를 나열하지 않고, **Route가 Gateway를 가리킵니다**(`parentRefs`).
그래서 Gateway 소유자가 Route 목록을 관리할 필요가 없습니다.

### 3. 표준 스펙 + AWS 확장

| 그룹 | 리소스 | 출처 |
|------|--------|------|
| `gateway.networking.k8s.io/v1` | GatewayClass, Gateway, HTTPRoute | **쿠버네티스 공식** (SIG-Network) |
| `gateway.k8s.aws/v1` | LoadBalancerConfiguration, TargetGroupConfiguration | **AWS 확장** |

Gateway API는 **벤더 중립**이라 "인터넷 노출 여부" 같은 AWS 고유 개념이 없습니다.
그래서 AWS가 별도 CRD로 제공하고, Gateway가 `infrastructure.parametersRef`로 참조합니다.

- 표준 CRD는 **별도 설치** (`kubectl apply -f .../standard-install.yaml`)
- AWS 확장 CRD는 **Helm 차트가 함께 설치**

> 쿠버네티스 코어에 내장돼 있지 않고 **CRD로 배포**된다는 점이 Ingress와 다릅니다.

### 4. 컨트롤러는 트래픽 경로에 없습니다 (직접 확인)

가장 헷갈리기 쉬운 부분입니다. **두 흐름이 완전히 분리**돼 있습니다.

```
┌─ 설정 흐름 (오브젝트가 바뀔 때만) ──────────────────┐
│  Gateway/HTTPRoute/EndpointSlice 변경               │
│         ↓ watch                                     │
│  LB Controller (클러스터 안)                         │
│         ↓ AWS 관리 API 호출                          │
│  AWS ELB 서비스 → ALB 설정 갱신                      │
└─────────────────────────────────────────────────────┘

┌─ 트래픽 흐름 (매 요청) ─────────────────────────────┐
│  사용자 → ALB → 10.0.61.87:8080 (파드)              │
│  ※ 컨트롤러는 여기 없음                              │
└─────────────────────────────────────────────────────┘
```

**실험으로 증명했습니다** — 컨트롤러를 0개로 내려도 트래픽이 정상이었습니다:

```
kubectl scale -n kube-system deployment/aws-load-balancer-controller --replicas=0
→ 컨트롤러 파드: No resources found
→ curl 결과: brsrv / 4pqqz / brsrv    ← 로드밸런싱까지 정상
```

#### 표현 정밀화: "컨트롤러가 ALB에게 요청한다"

두 군데를 다듬어야 합니다.

- **대상**: ALB가 아니라 **AWS 관리 API**(`elasticloadbalancing.ap-northeast-2.amazonaws.com`)입니다.
  ALB의 DNS 주소에는 컨트롤러가 한 번도 접속하지 않습니다 — 그건 사용자 트래픽용입니다.
  IAM 정책에 `elasticloadbalancing` 액션이 40개나 필요했던 이유가 이것입니다.
- **종류**: "요청"이 아니라 **"설정"** 입니다.

| | 컨트롤러 → AWS API | 사용자 → ALB |
|---|--------------------|--------------|
| 내용 | "이 규칙을 새겨라" | "이 페이지를 달라" |
| 빈도 | 오브젝트가 바뀔 때 | 매 요청 |
| 끊기면 | 변경만 반영 안 됨 | **서비스 중단** |

> 비유: 컨트롤러는 **표지판을 세우는 사람**, ALB는 **도로**입니다.
> 표지판 세우는 사람이 퇴근해도 차는 다닙니다.

다른 구현체와 비교하면 선명합니다.

| | **ALB (오늘)** | ingress-nginx |
|---|---------------|---------------|
| 데이터플레인 | AWS ALB (클러스터 **밖**) | nginx 파드 (클러스터 **안**) |
| 컨트롤러 | 트래픽 경로 **밖** | nginx와 같은 파드 |
| 컨트롤러 장애 시 | 트래픽 정상 | **트래픽 중단** |

### 5. Service는 ClusterIP가 맞습니다 (LoadBalancer 아님)

```
NAME                  TYPE        CLUSTERIP        NODEPORT
myapp-deepagent-app   ClusterIP   172.20.164.110   <none>
```

NodePort도 없는데 인터넷 접근이 됩니다. **트래픽이 Service를 거치지 않기 때문**입니다.

```
❌ 예상: ALB → Service(NodePort) → kube-proxy → 파드
✅ 실제: ALB → 파드 IP (10.0.61.87:8080)      ← Service를 안 지나감
```

#### 그럼 Service는 왜 필요한가 — **주소록** 역할

HTTPRoute의 `backendRef`는 "이 Service 뒤의 파드들로 보내라"는 **선언**입니다.
컨트롤러가 그걸 읽고 **EndpointSlice**를 조회합니다.

```
EndpointSlice (Service가 자동 관리)
  10.0.61.87   ready=true
  10.0.61.226  ready=true
        │ 컨트롤러가 watch
        ▼
  AWS API: RegisterTargets
        ▼
  타깃 그룹 → ALB가 이 목록에서 골라 전달
```

**ALB는 쿠버네티스를 전혀 모릅니다.** 요청마다 묻는 게 아니라 미리 등록된 목록에서 고릅니다.

| Service 타입 | 앞단이 Gateway/Ingress일 때 |
|--------------|---------------------------|
| **ClusterIP** ✅ | 표준. `targetType: ip`와 조합 |
| NodePort | `targetType: instance`일 때만 |
| LoadBalancer | ❌ **LB가 중복 생성** (ALB + NLB, 돈만 두 배) |

### 6. HTTPRoute → ALB 리스너 규칙으로 번역됩니다

컨트롤러가 실제로 새긴 것:

```
우선순위 1        | path=/healthz, /healthz/*  → forward 타깃그룹
우선순위 2        | path=/*                    → forward 타깃그룹
우선순위 default  | (조건 없음)                → fixed-response (404)
```

- **HTTPRoute의 rule 순서가 우선순위**가 됩니다.
  `/healthz`를 먼저 써서 우선순위 1을 받았습니다.
  순서를 바꿨다면 `/healthz` 요청도 catch-all에 먼저 걸렸을 겁니다.
- **정의되지 않은 경로는 `default` 규칙에 걸려 404**입니다.
  우리는 `/*` catch-all을 넣어 전부 열어둔 상태입니다.

## Terraform이 한 일 / 하지 않은 일

| 계층 | 도구 | 내용 |
|------|------|------|
| 권한 | **Terraform** | IAM 정책·역할·Pod Identity 연결 |
| 컨트롤러 | **Helm** | LB Controller 설치 |
| Gateway API | **kubectl** | CRD, GatewayClass/Gateway/HTTPRoute |
| **ALB·타깃그룹·보안그룹** | **컨트롤러가 자동** | ⚠️ Terraform state 밖! |

### 권한을 먼저 준비한 이유

컨트롤러가 권한 없이 뜨면 `AccessDenied` 로그만 쏟습니다.
그래서 **"권한 준비 → 컨트롤러 설치"** 순서입니다.

Pod Identity 연결은 **SA가 아직 없어도 만들어집니다** —
AWS는 쿠버네티스 쪽에 그 SA가 실제로 있는지 검사하지 않기 때문입니다.

### IAM 정책은 공식 파일을 그대로

`terraform/policies/alb-controller-policy.json`
(출처: kubernetes-sigs/aws-load-balancer-controller v3.5.0 `docs/install/iam_policy.json`)

| 서비스 | Action 수 |
|--------|-----------|
| `elasticloadbalancing` | 40 |
| `ec2` | 22 |
| `wafv2` / `shield` / `waf-regional` | 12 |
| `iam` | 3 (서비스 연결 역할 생성) |
| `acm` / `cognito-idp` | 3 |

**Statement 16개 / Action 80개.** 직접 추려 쓰지 않는 이유는
컨트롤러 버전이 오르면 필요 권한도 바뀌어서, "되다 안 되는" 디버깅에 시간을 버리기 때문입니다.

### Day 7의 Pod Identity를 그대로 사용

```hcl
Principal = { Service = "pods.eks.amazonaws.com" }
Action    = ["sts:AssumeRole", "sts:TagSession"]
```

**`serviceAccount.annotations`를 주지 않는 게 포인트**입니다.
IRSA라면 역할 ARN 애노테이션이 필요하지만, Pod Identity는 AWS 쪽 association이 처리합니다.
확인:

```bash
kubectl get sa -n kube-system aws-load-balancer-controller -o jsonpath='{.metadata.annotations}'
# → Helm 메타데이터만. eks.amazonaws.com/role-arn 없음
```

## ⚠️ Day 1 코드를 보강해야 했습니다

`network.tf`의 서브넷에 태그를 추가했습니다.

```hcl
"kubernetes.io/cluster/${var.project}-cluster" = "shared"
```

LBC의 `SubnetsClusterTagCheck`가 기본 활성이라 **이 태그가 없으면
"서브넷을 찾을 수 없다"며 ALB 생성이 실패**합니다.
Day 1에 `kubernetes.io/role/elb`만 붙였는데 그것만으로는 부족했습니다.

서브넷 재생성 없이 **태그만 in-place 수정**됐습니다 (`4 to change`).

## 실습 순서

```bash
# 1) 권한 준비
make plan     # "Plan: 4 to add, 4 to change"
make apply

# 2) Gateway API CRD (표준 스펙)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml

# 3) 컨트롤러 설치 — CRD가 있어야 Gateway API 기능이 켜집니다
helm repo add eks https://aws.github.io/eks-charts && helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 3.5.0 --namespace kube-system \
  --set clusterName=deepagent-eks-lab-cluster \
  --set region=ap-northeast-2 \
  --set vpcId=$(terraform -chdir=terraform output -raw vpc_id) \
  --wait

# 4) 권한 확인
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=30 | grep -i denied
kubectl get pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}' | tr ' ' '\n' | grep AWS_CONTAINER

# 5) Gateway 생성 → 💸 ALB 생성
kubectl apply -f k8s/day08/

# 6) 확인
kubectl get gateway -n demo                      # PROGRAMMED=True 까지 2~4분
aws elbv2 describe-target-health --target-group-arn <TG_ARN>

# 7) 인터넷 접근
HOST=$(kubectl get gateway -n demo app-gateway -o jsonpath='{.status.addresses[0].value}')
curl -s "http://$HOST" | jq
```

**CRD를 먼저 깔고 컨트롤러를 설치하는 순서가 중요**합니다 —
컨트롤러는 시작할 때 Gateway API CRD가 있는지 보고 기능을 켤지 정합니다.
순서가 바뀌면 컨트롤러를 재시작해야 합니다.

## 막혔던 지점 — 오히려 좋은 학습 재료

### ① `TargetGroup port is empty`

```
TargetGroup port is empty. When using Instance targets,
your service must be of type 'NodePort' or 'LoadBalancer'
```

**원인**: 기본 `targetType`이 `instance`. 그 모드는 노드의 NodePort로 보내는 방식이라
Service가 NodePort/LoadBalancer여야 하는데, 우리 Service는 ClusterIP였습니다.

**해결**: `TargetGroupConfiguration`으로 `targetType: ip` 지정

```
instance : ALB → 노드:NodePort → kube-proxy(iptables) → 파드    홉 2번
ip       : ALB → 파드 IP                                       홉 1번  ← 채택
```

**이게 Day 6에서 배운 VPC CNI의 이점이 실제로 쓰인 순간**입니다.
파드가 진짜 VPC IP를 갖기 때문에 ALB가 그 IP를 타깃으로 등록할 수 있습니다.
오버레이 네트워크였다면 불가능했습니다.

증거:
```
타깃 그룹:  10.0.61.226:8080  healthy
            10.0.61.87 :8080  healthy
파드 IP  :  10.0.61.226, 10.0.61.87        ← 정확히 일치
```

### ② `unknown field healthCheckIntervalSeconds`

```
strict decoding error: unknown field
"spec.defaultConfiguration.healthCheckConfig.healthCheckIntervalSeconds"
```

올바른 필드명은 `healthCheckInterval`이었습니다.
**Ingress 애노테이션이었다면 조용히 무시되고 기본값으로 돌았을 것**입니다.
Gateway API의 스키마 검증 이점을 몸으로 확인한 셈입니다.

CRD 스키마를 직접 조회해 해결했습니다:
```bash
helm show crds eks/aws-load-balancer-controller --version 3.5.0
```

## 관찰 포인트

1. 컨트롤러를 0개로 내리면 트래픽이 끊길까요? 왜?
2. Service가 ClusterIP인데 인터넷 접근이 되는 이유는?
3. Service를 LoadBalancer로 바꾸면 무슨 일이 생기나요?
4. HTTPRoute의 rule 순서를 바꾸면 무엇이 달라지나요?
5. `targetType: ip`가 가능한 전제 조건은? (Day 6과 연결)
6. GatewayClass는 왜 클러스터 전역이고 Gateway는 네임스페이스 스코프인가요?

## ⚠️ 정리 순서 — Day 8부터 중요해집니다

**컨트롤러가 만든 AWS 리소스는 Terraform state 밖에 있습니다.**

```
ALB · 타깃 그룹 · 리스너 · 보안그룹 2개   ← terraform destroy가 모름
```

반드시 이 순서로:

```bash
# 1) Gateway 오브젝트 삭제 → 컨트롤러가 ALB를 정리
kubectl delete -f k8s/day08/

# 2) ALB가 정말 사라졌는지 확인 (2~3분)
aws elbv2 describe-load-balancers --region ap-northeast-2 --query "length(LoadBalancers)"
#   → 0 이 될 때까지 대기

# 3) 컨트롤러 제거
helm uninstall aws-load-balancer-controller -n kube-system

# 4) 인프라 정리
make destroy
```

**Gateway를 남긴 채 `make destroy`하면** ALB가 고아로 남아 계속 과금되고,
ALB의 ENI가 서브넷 삭제를 막아 terraform이 실패합니다.

### 실제로 겪은 사고 (2026-09-09)

위 경고를 적어두고도 바로 당했습니다. **Gateway 삭제와 `make destroy`를 동시에 시작**한 게 원인입니다.

```
Gateway 삭제 요청 → 컨트롤러가 ALB를 지우기 시작
       (동시에)
make destroy      → 노드 그룹부터 삭제 → 컨트롤러 파드 사망 💀
                     ↓
            ALB를 지워줄 주체가 사라짐
                     ↓
   destroy가 41개 → 13개에서 멈춤 (ALB의 ENI가 서브넷 삭제를 막음)
```

**컨트롤러가 죽으면 ALB는 영원히 남습니다.** Terraform은 그 존재를 모르고,
쿠버네티스에는 이미 컨트롤러가 없습니다.

#### 수동 복구 — 삭제에 의존성 순서가 있습니다

```bash
# ① ALB 먼저 (타깃 그룹을 리스너가 물고 있어서 순서를 바꾸면 실패)
aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN>

# ② ALB가 사라진 뒤 타깃 그룹
aws elbv2 delete-target-group --target-group-arn <TG_ARN>
#   순서를 어기면: ResourceInUse: Target group ... is currently in use by a listener or a rule

# ③ ALB의 ENI가 사라진 뒤 보안그룹 2개
aws ec2 delete-security-group --group-id <SG_ID>   # k8s-demo-appgatew-...
aws ec2 delete-security-group --group-id <SG_ID>   # k8s-traffic-<클러스터>-...

# ④ destroy 재개
make destroy
```

보안그룹은 서로 참조 관계가 있어 **한 번 실패하면 잠시 후 재시도**해야 합니다.

#### 교훈

| | |
|---|---|
| **동시에 하지 말 것** | Gateway 삭제가 **완료된 뒤** destroy를 시작 |
| **0을 눈으로 확인** | `describe-load-balancers --query "length(LoadBalancers)"` 가 `0` |
| 순서 기억 | ALB → 타깃 그룹 → 보안그룹 (역순은 `ResourceInUse`) |
| 비용 영향 | 다행히 금전 손해는 없었음 — 즉시 발견해 정리 |

> 이 사고는 **"쿠버네티스 오브젝트가 만든 AWS 리소스"의 수명주기가
> Terraform과 분리돼 있다**는 것을 몸으로 알려줍니다.
> Day 9(EBS CSI)에서도 같은 성격의 문제가 반복됩니다 —
> PVC가 만든 EBS 볼륨 역시 Terraform state 밖입니다.

## 비용 메모

| | 시간당 |
|---|---|
| Day 7까지 | $0.24 |
| **ALB** | +$0.0225 + LCU |
| 퍼블릭 IPv4 2개 (AZ당) | +$0.01 |
| **합계** | **≈ $0.28** |

IAM 정책·역할·연결·서브넷 태그·CRD·컨트롤러는 전부 **$0**입니다.
비용은 오직 **ALB가 생기는 5단계부터** 발생합니다.

## Phase 1 완료

```
Day 5  ECR + Helm으로 내 앱 배포
Day 6  핵심 애드온 (VPC CNI · kube-proxy · CoreDNS)
Day 7  IRSA / Pod Identity
Day 8  Gateway API + ALB          ← 앱이 인터넷에 공개됨
```

Day 1의 서브넷 태그, Day 3의 노드 정책, Day 6의 VPC CNI, Day 7의 Pod Identity가
**모두 오늘 하나로 모였습니다.**

## 다음 (Day 9)

**스토리지 (EBS/EFS CSI)** — PersistentVolume / PVC / StorageClass.
CSI 드라이버도 AWS 권한이 필요한데, **Day 7에서 배운 방식으로 줍니다** —
Day 8의 LB Controller와 같은 패턴이 반복됩니다.
