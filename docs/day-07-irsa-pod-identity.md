# Day 7 — 파드에 AWS 권한 주기 (IRSA · Pod Identity)

> 목표: 파드가 AWS API를 부를 수 있게 만들고, **파드별로** 권한을 좁힌다.
> Day 5에서 본 ServiceAccount 토큰의 OIDC 발급자가 여기서 쓰입니다.

## 먼저 정정 — 문제의 정체가 예상과 달랐습니다

Day 3·6 노트에 **"노드 역할의 권한을 그 노드의 모든 파드가 공유한다"** 고 적었는데,
**EKS 관리형 노드 그룹에서는 사실이 아닙니다.** 직접 확인한 결과:

```
노드 IMDS 설정: HttpTokens=required, HttpPutResponseHopLimit=1

일반 파드        → NoCredentials: Unable to locate credentials
hostNetwork 파드 → arn:aws:sts::...:assumed-role/deepagent-eks-lab-node-role/i-04b81...
```

**기본 상태는 "모두가 노드 권한을 공유"가 아니라 "파드에 권한이 아예 없음"** 입니다.
그래서 IRSA가 필요한 이유는 "너무 넓은 권한을 좁히려고"가 아니라 **"없는 권한을 주려고"** 입니다.

> 단, 자체 관리 노드나 홉 제한을 2로 바꾼 구성에서는 원래 말한 문제가 실제로 발생합니다.
> 그래서 **IMDS 홉 제한이 중요한 보안 설정**입니다.

## IMDS와 홉 제한

### IMDS = Instance Metadata Service

EC2 안에서만 접근되는 링크 로컬 주소 **`169.254.169.254`** 의 HTTP 서비스입니다.

```
/latest/meta-data/instance-id
/latest/meta-data/placement/availability-zone
/latest/meta-data/iam/security-credentials/<역할명>   ← 🔑 역할의 임시 자격증명
```

마지막 항목이 핵심입니다. EC2에 IAM 역할을 붙이면 그 역할의 임시 키를 IMDS가 내줍니다.
EC2에서 `aws` CLI가 자격증명 설정 없이 동작하는 이유이고,
Day 3에서 "노드가 인스턴스 프로파일로 역할을 빌린다"고 한 것의 실제 구현입니다.

### IMDSv1 vs v2

| | v1 | **v2 (현재 `required`)** |
|---|-----|------------------------|
| 방식 | 그냥 `GET` | **`PUT`으로 토큰 먼저** → 헤더에 실어 `GET` |
| SSRF 취약성 | ⚠️ 높음 | 낮음 |

v1의 문제는 유명합니다. 앱에 "URL을 입력받아 가져오는" 기능이 있으면 공격자가
`http://169.254.169.254/latest/meta-data/iam/security-credentials/`를 넣어
**AWS 자격증명을 탈취**할 수 있었습니다. v2는 PUT + 커스텀 헤더를 요구해 막았습니다.

### 홉 제한(HttpPutResponseHopLimit)

IMDS **응답 패킷의 IP TTL 값**입니다. TTL은 라우팅 한 번에 1씩 줄고 0이면 폐기됩니다.

```
TTL=1 로 응답
   ├─ 호스트 자신이 받음          → ✅ 도착 (홉 0)
   └─ 파드로 가려면?
      호스트가 veth로 라우팅 → TTL 1→0 → 💀 폐기
```

파드는 자기 네트워크 네임스페이스에 있어 **호스트 라우팅을 한 번 거칩니다.**
그 한 홉 때문에 응답이 도달하지 못합니다.
hostNetwork 파드는 호스트 네트워크를 공유하므로 홉이 안 늘어나 통과합니다 —
그래서 `aws-node`가 노드 역할을 쓸 수 있습니다.

**홉 제한 1 = "컨테이너가 노드 자격증명을 훔쳐 쓰지 못하게" 막는 보안 장치**이고,
EKS 관리형 노드 그룹이 기본으로 켜둡니다.

## ServiceAccount란

**파드 안에서 도는 프로세스에게 주는 쿠버네티스 신원**입니다.

| | User | **ServiceAccount** |
|---|------|-------------------|
| 대상 | **사람** | **파드(프로세스)** |
| 쿠버네티스가 관리? | ❌ 외부에서 옴 (IAM, 인증서, OIDC…) | ✅ 클러스터 안의 리소스 |
| 생성 | 불가 (`kubectl create user`는 없음) | `kubectl create sa` |
| 네임스페이스 | 없음 (전역) | 있음 |

Day 4의 `kubectl auth whoami`가 저를 `arn:aws:iam::...:user/deepagent`로 보여준 건
**User**입니다 — IAM에서 번역돼 들어온 외부 신원이죠.
ServiceAccount는 **쿠버네티스가 직접 발급하는 내부 신원**입니다.

### 모든 파드는 SA를 갖습니다

```
POD                                    SA
myapp-deepagent-app-5c78764c7b-brsrv   default
```

지정하지 않으면 네임스페이스의 `default` SA가 자동 할당됩니다.

### 토큰이 파일로 주입됩니다

```
볼륨: kube-api-access-xxxxx
  serviceAccountToken → token | 만료: 3607초
  configMap     (CA 인증서)
  downwardAPI   (네임스페이스)
마운트: /var/run/secrets/kubernetes.io/serviceaccount
```

내용:

```
iss : https://oidc.eks.ap-northeast-2.amazonaws.com/id/5310...   ← IRSA의 출발점
sub : system:serviceaccount:demo:default
aud : ['https://kubernetes.default.svc']
```

- **`sub`** = `system:serviceaccount:<네임스페이스>:<SA이름>` — 쿠버네티스가 인식하는 이름
- **`aud`** = 이 토큰을 제시할 **대상**. 여기서는 쿠버네티스 API 서버
- **`iss`** = EKS가 클러스터마다 운영하는 OIDC 발급자

> 옛 쿠버네티스(1.23 이하)는 만료 없는 토큰을 Secret에 영구 저장했습니다.
> 지금은 **짧은 수명 + 대상 고정 + 파일 주입**으로 바뀌었습니다.

SA의 본래 용도는 "파드가 쿠버네티스 API를 부를 때 신원을 밝히는 것"이고,
**AWS 권한과는 아무 관계가 없습니다.** 그 간극을 메우는 게 IRSA/Pod Identity입니다.

## 방법 A — IRSA (IAM Roles for Service Accounts)

**ServiceAccount의 JWT를 AWS가 신뢰하게 만들어, 파드가 IAM 역할을 빌리게 하는 방식**입니다.

```
① IAM에 OIDC provider 등록
   "oidc.eks.ap-northeast-2.amazonaws.com/id/5310... 이 발급한 토큰을 신뢰한다"

② 역할의 신뢰 정책
   Principal: Federated = 그 OIDC provider
   Action   : sts:AssumeRoleWithWebIdentity        ← AssumeRole이 아님
   Condition: sub = "system:serviceaccount:demo:irsa-demo"   ← SA를 못박음
              aud = "sts.amazonaws.com"

③ ServiceAccount에 애노테이션
   eks.amazonaws.com/role-arn: arn:aws:iam::...:role/...

④ 실행 시 EKS 웹훅이 파드에 주입
   AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE + aud=sts.amazonaws.com 토큰 볼륨
   → AWS SDK가 스스로 sts:AssumeRoleWithWebIdentity 호출
```

### 신뢰하는 대상이 Day 2·3과 또 다릅니다

| 역할 | Principal | Action |
|------|-----------|--------|
| 클러스터 역할 (Day 2) | `Service = eks.amazonaws.com` | `sts:AssumeRole` |
| 노드 역할 (Day 3) | `Service = ec2.amazonaws.com` | `sts:AssumeRole` |
| **IRSA 역할 (Day 7)** | **`Federated = OIDC provider ARN`** | **`sts:AssumeRoleWithWebIdentity`** |

"웹 토큰을 제시하며 역할을 빌린다"는 뜻입니다.

### ⚠️ `sub` 조건을 빼면 안 됩니다

조건이 없으면 **이 클러스터의 아무 ServiceAccount나** 그 역할을 빌릴 수 있습니다.
흔한 보안 실수이고, 실습 7단계에서 직접 확인할 수 있습니다.

## 방법 B — EKS Pod Identity

**(클러스터, 네임스페이스, SA) → IAM 역할 매핑을 EKS API에 등록하고,
노드의 에이전트가 자격증명을 전달하는 방식**입니다. 2023년 말 등장.

```
① 에이전트 설치 (eks-pod-identity-agent 애드온, DaemonSet)

② 역할의 신뢰 정책 — 훨씬 단순
   Principal: Service = pods.eks.amazonaws.com
   Action   : sts:AssumeRole, sts:TagSession     ← TagSession이 추가로 필요
   (OIDC URL도, sub 조건도 없음)

③ 연결(association) 등록 — AWS 쪽에
   cluster + namespace + serviceAccount → role

④ 실행 시 AWS_CONTAINER_CREDENTIALS_FULL_URI 주입 (에이전트 주소)
   → SDK가 에이전트에게 요청 → 에이전트가 대신 역할을 빌려옴
```

`TagSession`이 필요한 이유는 Pod Identity가 세션에 네임스페이스/SA 정보를
**태그로 심기** 때문입니다.

**ServiceAccount에 애노테이션이 없습니다.** 매핑 정보가 쿠버네티스 밖(AWS)에 있습니다 —
Day 4의 Access Entry와 같은 사고방식입니다.

## 비교

| | IRSA | Pod Identity |
|---|------|--------------|
| 등장 | 2019 | 2023 말 |
| OIDC provider | **클러스터마다 등록 필요** | 불필요 |
| 역할 신뢰 정책 | 클러스터 OIDC URL이 박힘 → **재사용 어려움** | `pods.eks.amazonaws.com` 고정 → **여러 클러스터 재사용** |
| 매핑 위치 | 역할 조건 + SA 애노테이션 (**두 곳 분산**) | association 한 곳 |
| 추가 설치 | 없음 | 에이전트 DaemonSet |
| 주입 방식 | **토큰 파일** (SDK가 직접 STS 호출) | **에이전트 주소** (에이전트가 처리) |
| 세션 이름 | SDK 임의값 (`botocore-session-...`) | **클러스터+파드명 포함** → CloudTrail 추적 용이 |
| EKS 전용? | ❌ OIDC 지원하는 아무 쿠버네티스에서 가능 | ✅ EKS 전용 |
| `sub` 조건 실수 위험 | 있음 | 구조적으로 없음 |

**새로 만든다면 Pod Identity**가 간단하고 감사 추적도 좋습니다.
**IRSA를 쓰는 경우**: 기존 구성이 IRSA이거나, EKS 밖에서도 같은 방식을 쓰고 싶을 때.
생태계 자료와 Helm 차트가 대부분 IRSA를 가정한다는 점도 현실적인 이유입니다.

> 크로스 계정 역할 사용 등 세부 기능은 차이가 있을 수 있으니 실제 적용 시 AWS 문서로 확인하세요.

## 오늘 만든 것

`terraform/eks-irsa.tf` — 7개 리소스 (**비용 $0**)

```
방법 A (IRSA)
  data.tls_certificate.eks_oidc          OIDC 인증서 지문 계산
  aws_iam_openid_connect_provider.eks    IAM에 발급자 등록
  aws_iam_role.irsa_demo                 Federated 신뢰 + sub 조건
  aws_iam_role_policy.irsa_demo          s3:ListAllMyBuckets

방법 B (Pod Identity)
  aws_eks_addon.pod_identity             에이전트 DaemonSet (네 번째 애드온)
  aws_iam_role.pod_identity_demo         pods.eks.amazonaws.com 신뢰
  aws_iam_role_policy.pod_identity_demo  같은 권한
  aws_eks_pod_identity_association.demo  (demo, podid-demo) → 역할
```

`versions.tf`에 `tls` provider를 추가했습니다 (OIDC 지문 계산용).

`k8s/day07/` — ServiceAccount 2개 + 비교용 파드 3개

### 권한을 `s3:ListAllMyBuckets`로 고른 이유

노드 역할에는 `AmazonEC2ContainerRegistryReadOnly`가 있어서,
**ECR로 실험하면 "IRSA 덕분인지 노드 역할 덕분인지" 구분이 안 됩니다.**
`s3:ListAllMyBuckets`는 노드 역할에 없으므로 차이가 분명히 드러납니다.

## 실습 순서

```bash
make plan     # "Plan: 7 to add"
make apply

terraform -chdir=terraform output oidc_provider_arn
kubectl get ds -n kube-system eks-pod-identity-agent    # 2/2 Ready

# ServiceAccount — 애노테이션 유무를 비교해 보세요
kubectl apply -f k8s/day07/irsa.yaml
kubectl apply -f k8s/day07/podidentity.yaml
kubectl get sa -n demo irsa-demo  -o yaml | grep -A2 annotations   # 있음
kubectl get sa -n demo podid-demo -o yaml | grep -A2 annotations   # 없음

# 세 파드 비교
kubectl apply -f k8s/day07/test-pods.yaml
sleep 25
for P in awsid-none awsid-irsa awsid-podid; do
  echo "─── $P ───"; kubectl logs -n demo $P
done
```

## 실제 결과와 읽는 법

### awsid-none — 파드에 권한이 없다는 증명

```
NoCredentials: Unable to locate credentials
```

IMDS 홉 제한에 막히고 다른 경로도 없습니다. **EKS의 기본 상태입니다.**

### awsid-irsa

```
arn:aws:sts::...:assumed-role/deepagent-eks-lab-irsa-demo-role/botocore-session-1788934272
                                                                ▲ SDK가 직접 만든 세션 이름
AWS_ROLE_ARN=arn:aws:iam::...:role/deepagent-eks-lab-irsa-demo-role
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
                                              ▲ kubernetes.io가 아님!
AWS_STS_REGIONAL_ENDPOINTS=regional
--- s3 ls ---
2026-09-07 04:23:24 deepagent-eks-tfstate
```

**`botocore-session-...`** — botocore는 Python AWS SDK의 내부 이름입니다.
**SDK가 스스로 `AssumeRoleWithWebIdentity`를 호출했다는 증거**입니다.

### 토큰이 두 개 주입됩니다 (직접 확인)

| 토큰 경로 | `aud` | 용도 |
|-----------|-------|------|
| `kubernetes.io/serviceaccount/token` | `https://kubernetes.default.svc` | **쿠버네티스 API** |
| `eks.amazonaws.com/serviceaccount/token` | `sts.amazonaws.com` | **AWS STS** |

`sub`는 둘 다 `system:serviceaccount:demo:irsa-demo`로 같습니다.
**같은 신원, 다른 대상** — 이게 `aud`의 존재 이유입니다.
쿠버네티스용 토큰을 AWS에 제시해도 `aud`가 안 맞아 거부되므로,
토큰이 엉뚱한 곳에 재사용되는 걸 막습니다.

### awsid-podid

```
arn:aws:sts::...:assumed-role/deepagent-eks-lab-podid-demo-role/eks-deepagent--awsid-podi-3e93a8db-...
                                                                 ▲ 클러스터명 + 파드명!
AWS_CONTAINER_CREDENTIALS_FULL_URI=http://169.254.170.23/v1/credentials
AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE=/var/run/secrets/pods.eks.amazonaws.com/...
--- s3 ls ---
2026-09-07 04:23:24 deepagent-eks-tfstate
```

IRSA의 `botocore-session-1788934272`와 비교해보세요.
**Pod Identity는 EKS가 세션 이름에 클러스터와 파드 이름을 심습니다.**
그래서 **CloudTrail에서 "어느 파드가 이 API를 불렀는지" 추적이 됩니다.**
실무에서 Pod Identity를 선호하는 실질적 이유 중 하나입니다.

- `169.254.170.23` — IMDS와 마찬가지로 링크 로컬 주소지만,
  에이전트는 일반 TCP 서비스라 **TTL 제약이 없어** 파드에서 닿습니다
- 두 번째 토큰은 **AWS가 아니라 에이전트에게** 자신을 증명하는 용도입니다

## sub 조건의 중요성 (직접 확인)

```bash
kubectl create sa fake-sa -n demo
kubectl annotate sa fake-sa -n demo \
  eks.amazonaws.com/role-arn=$(terraform -chdir=terraform output -raw irsa_demo_role_arn)

kubectl run fake --rm -i --restart=Never -n demo \
  --overrides='{"spec":{"serviceAccountName":"fake-sa"}}' \
  --image=public.ecr.aws/aws-cli/aws-cli:latest \
  --command -- aws sts get-caller-identity
```

`AccessDenied`가 납니다 — 신뢰 정책의 `sub`가 `demo:irsa-demo`로 못박혀 있기 때문입니다.
**이 조건을 빼면 클러스터의 아무 SA나 역할을 빌릴 수 있습니다.**

## 이제 클러스터에 신원이 세 종류입니다

| 주체 | 신원 출처 | 확인 방법 |
|------|-----------|-----------|
| **사람** | IAM 사용자 → Access Entry (Day 4) | `kubectl auth whoami` |
| **노드** | 노드 역할 → IMDS (hostNetwork만) | hostNetwork 파드에서 `get-caller-identity` |
| **파드** | SA → IRSA / Pod Identity (Day 7) | 위 실험 |

Day 4의 "문지기가 둘" 구조가 파드 차원으로 확장된 셈입니다.

## 관찰 포인트

1. 일반 파드에 자격증명이 없는 이유를 TTL로 설명할 수 있나요?
2. IRSA 파드에 토큰이 왜 두 개 주입되나요? `aud`가 다른 이유는?
3. 세션 이름만 보고 IRSA인지 Pod Identity인지 구분할 수 있나요?
4. `sub` 조건을 빼면 어떤 공격이 가능해지나요?
5. 실습 권한으로 ECR이 아니라 S3를 고른 이유는?

## 비용 메모

- **오늘 추가 비용 $0** — IAM 리소스, OIDC provider, Pod Identity 에이전트 모두 무료
- 에이전트는 노드 자원을 약간 씁니다 (최대 파드 17개 중 1개 차지)
- 시간당 합계 그대로 **≈ $0.24**

## 정리

```bash
kubectl delete -f k8s/day07/test-pods.yaml
kubectl delete sa fake-sa -n demo 2>/dev/null
```

## 다음 (Day 8)

**Gateway API + AWS Load Balancer Controller.**
지금 앱은 `port-forward`로만 접근 가능합니다. 이제 인터넷에 노출합니다.
컨트롤러는 ALB를 만들 AWS 권한이 필요한데, **그 권한을 오늘 배운 방식으로 줍니다** —
Day 7이 Day 8의 전제입니다.
