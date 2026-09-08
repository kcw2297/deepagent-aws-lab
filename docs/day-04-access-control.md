# Day 4 — 접근 제어 (kubectl & IAM)

> 목표: **관리자 한 명 말고 다른 사람에게 클러스터 권한을 주는 법**을 배운다.
> 그 과정에서 "AWS 권한"과 "쿠버네티스 권한"이 별개라는 걸 몸으로 확인한다.

## 왜 이게 문제인가

Day 3까지 끝냈지만 클러스터를 조작할 수 있는 건 **나 한 명**입니다.
Day 2에 넣은 한 줄 때문입니다.

```hcl
bootstrap_cluster_creator_admin_permissions = true
```

이게 "클러스터를 만든 IAM 주체"를 위한 Access Entry를 자동 생성했습니다.
**즉 지금은 "나만 우연히 되는" 상태이고, 남에게 주는 법은 모릅니다.**

흔한 사고 시나리오:

> 팀에 새 개발자가 왔습니다. AWS 계정 만들어줬고, `aws configure`도 했고,
> `aws eks update-kubeconfig`도 성공했습니다. 그런데:
>
> ```
> error: You must be logged in to the server (Unauthorized)
> ```

**AWS 권한이 있어도 쿠버네티스 권한은 없기 때문**입니다.

## 문지기가 둘이다

```
  나 ──①──► AWS (STS)      "너 누구야?"        → 신분증(토큰) 발급
     ──②──► 쿠버네티스      "뭘 할 수 있어?"    → 허용 / 거부
                 ▲
          이 사이를 잇는 게 Access Entry
```

두 시스템은 원래 서로를 모릅니다. **바닐라 쿠버네티스는 IAM이라는 개념 자체가 없습니다.**
ARN이 뭔지, STS가 뭔지 모릅니다. Access Entry가 그 사이를 번역합니다.

## 핵심 개념

### 1. kubectl은 어떻게 인증하나 — 비밀번호가 없다

kubeconfig에 저장된 건 토큰이 아니라 **명령어**입니다.

```
command: aws
args:    --region ap-northeast-2 eks get-token --cluster-name <클러스터>
apiVersion: client.authentication.k8s.io/v1beta1
```

`kubectl`이 API를 부를 때마다 이 명령을 실행해 **그 자리에서 토큰을 발급**받습니다
(exec credential plugin). 그래서 **kubeconfig에는 영구 비밀정보가 없습니다.**
파일이 유출돼도 그 자체로는 못 들어갑니다 — AWS 자격증명이 있어야 합니다.

### 2. 그 토큰의 정체 — presigned STS URL

토큰을 디코딩하면 이렇습니다.

```
접두사   : k8s-aws-v1
호스트   : sts.ap-northeast-2.amazonaws.com
Action   : GetCallerIdentity        ← "이 요청 보낸 게 누구야?"
서명헤더 : host;x-k8s-aws-id
Signature: <서명>
```

**`GetCallerIdentity`를 부르는 presigned URL**입니다. presigned URL이란
서명을 쿼리스트링에 미리 박아 넣어, 그 URL을 가진 사람이 **서명자 자격으로**
요청 하나를 실행할 수 있게 한 주소입니다. (S3 공유 링크와 같은 원리)

#### 왜 이런 우회를 하나 — 비밀키를 안 넘기려고

```
❌ 순진한 방법: API 서버에 내 AWS 비밀키를 준다 → 서버가 내 키를 알게 됨. 위험.

✅ 실제 방법:
   1. kubectl이 GetCallerIdentity 요청을 자기 키로 서명   ← 키는 내 노트북 밖으로 안 나감
   2. 보내지 않고 서명된 URL만 API 서버에 건넴 (이게 토큰)
   3. API 서버가 그 URL을 대신 호출
   4. STS가 "이건 user/deepagent가 서명했다"고 답
   5. API 서버는 신원만 알게 됨. 키는 끝까지 못 봄.
```

**"내가 서명한 걸 남이 대신 실행하게 해서 서명자가 나임을 증명"** — 소유 증명입니다.

직접 실험해보면 확인됩니다. 토큰을 디코딩해 그 URL을 호출하면:

```
정상 (헤더 x-k8s-aws-id: <클러스터명>) → Arn: arn:aws:iam::...:user/deepagent  ✅
헤더 없음                              → SignatureDoesNotMatch                ❌
다른 클러스터명                        → SignatureDoesNotMatch                ❌
```

**클러스터 이름이 서명에 포함**되어 있습니다. 이게 없으면 악의적인 클러스터 A의
운영자가 내 토큰을 받아 **클러스터 B에 나인 척 재사용**할 수 있습니다.

> ⚠️ **토큰은 신분증이지 권한증이 아닙니다.** RBAC 정보가 한 글자도 없습니다.
> 권한은 요청할 때마다 API 서버가 그 자리에서 새로 판단합니다.

### 3. Access Entry란 정확히 무엇인가

**EKS가 클러스터마다 들고 있는 "IAM 신원 ↔ 쿠버네티스 신원" 번역표의 한 행**입니다.

```
┌─ Access Entry ───────────────────────────────────┐
│ principalArn : arn:aws:iam::...:user/deepagent   │ ← 입력 (AWS의 언어)
│─────────────────────────────────────────────────│
│ username     : arn:aws:iam::...:user/deepagent   │ ← 출력 (K8s의 언어)
│ k8sGroups    : []                                │
│ type         : STANDARD                          │
└─────────────────────────────────────────────────┘
        + 연결된 액세스 정책: AmazonEKSClusterAdminPolicy
```

#### 쿠버네티스 안에 있는 게 아닙니다

```bash
kubectl get accessentries
# → error: the server doesn't have a resource type "accessentries"
```

Pod나 ConfigMap처럼 클러스터(etcd)에 저장된 오브젝트가 **아닙니다.**
**EKS 서비스 쪽 AWS 리소스**이고 `aws eks` API / Terraform으로만 다룹니다.

#### Access Entry ≠ 액세스 정책

둘은 별개이고, 그래서 API도 나뉘어 있습니다.

```bash
aws eks describe-access-entry             # 신원 번역 (username, groups)
aws eks list-associated-access-policies   # 권한 (연결된 정책)
```

- **Access Entry만** 있으면 → 들어는 오지만 아무것도 못 함
- **정책까지** 연결해야 → 할 수 있는 일이 생김

권한을 얻는 경로는 두 가지입니다.

| 경로 | 방식 | 우리 사례 |
|------|------|-----------|
| 액세스 정책 연결 | AWS가 만든 RBAC 묶음 사용 | `user/deepagent` → ClusterAdmin |
| **그룹 매핑** | K8s 그룹에 넣고 그 그룹의 RBAC를 따름 | **노드 역할 → `system:nodes`** |

Day 3의 노드 역할은 **연결된 정책이 `[]`(비어 있음)인데도** 잘 동작합니다.
`system:nodes`가 쿠버네티스 내장 그룹이라 이미 바인딩이 걸려 있기 때문입니다.

### 4. 전체 흐름 — 어디까지가 인증이고 어디부터가 인가인가

```
kubectl get nodes
  │
  ├─① aws eks get-token → 신분증 발급 (IAM 신원만 담김)
  │
  ├─② API 서버가 STS로 검증 → "arn:...:user/deepagent 맞음"      ← 신원 확인은 STS가
  │
  ├─③ Access Entry 조회 → username + groups 로 번역              ← 인증 끝
  │
  └─④ RBAC 평가: "이 username이 nodes를 get 할 수 있나?"          ← 인가
```

**Access Entry는 "파악"이 아니라 "번역"입니다.** 신원 확인은 ②에서 STS가 끝냅니다.

### 5. 표준 쿠버네티스인가, EKS 전용인가

**골격은 표준, 내용물이 EKS 전용**입니다.

쿠버네티스는 인증기를 갈아끼울 수 있게 설계되어 있고(X.509, ServiceAccount 토큰,
OIDC, **Webhook 토큰 인증** 등), EKS는 그중 **Webhook 자리에 자기 구현을 꽂은 것**입니다.

```
쿠버네티스가 제공하는 규격              AWS가 채워넣은 구현
─────────────────────────             ──────────────────
Webhook 토큰 인증 (TokenReview)   ←──  aws-iam-authenticator
exec credential plugin 규격       ←──  aws eks get-token
                                       + presigned STS URL 형식
                                       + Access Entry 매핑표
```

증거 셋:
- kubeconfig의 `apiVersion: client.authentication.k8s.io/v1beta1` — **쿠버네티스 공식 API 그룹**
- `kubectl auth whoami`의 UID가 `aws-iam-authenticator:...` — AWS 웹훅의 지문
- **표준 방식도 같은 클러스터에서 동시에 동작**:

| | EKS IAM 토큰 | ServiceAccount 토큰 |
|---|---|---|
| 형식 | `k8s-aws-v1.<presigned URL>` | 표준 JWT (RS256) |
| 검증 주체 | **AWS STS** | **쿠버네티스 자신** |
| 주체 표기 | `arn:aws:iam::...:user/deepagent` | `system:serviceaccount:default:default` |
| 용도 | 사람이 kubectl 쓸 때 | 파드가 API 부를 때 |

다른 클라우드도 같은 자리에 각자 구현을 꽂습니다 — GKE는 Google OIDC,
AKS는 Entra ID. **"클라우드 IAM으로 kubectl 인증"은 공통 아이디어이고 구현이 다릅니다.**

> ServiceAccount 토큰의 발급자가 `https://oidc.eks.<리전>.amazonaws.com/id/...` 입니다.
> **Day 7 IRSA가 바로 이 OIDC를 이용**합니다. 오늘 나온 조각이 그때 다시 쓰입니다.

### 6. 옛 방식(aws-auth ConfigMap)과의 차이

```bash
kubectl get configmap aws-auth -n kube-system
# → Error: configmaps "aws-auth" not found
```

예전에는 번역표가 **클러스터 안의 ConfigMap**이었습니다.

| | `aws-auth` ConfigMap (구) | Access Entry (현재) |
|---|---|---|
| 저장 위치 | 클러스터 안 (etcd) | AWS 쪽 |
| 수정 방법 | `kubectl edit` | AWS API / Terraform |
| **YAML 오타 시** | **전원 잠김 → 복구 거의 불가** | AWS API로 언제든 수정 |
| 감사 로그 | 어려움 | CloudTrail에 기록 |

**"번역표를 고치려면 클러스터에 들어가야 하는데, 잘못 고치면 못 들어간다"** —
이 순환이 유명한 사고의 원인이었습니다.
Day 2에서 `authentication_mode = "API"`를 고른 이유가 이것입니다.

## 오늘 만드는 것 — 3계층에 하나씩

`terraform/eks-access.tf` (💰 비용 $0 — IAM 역할과 Access Entry는 무료)

```hcl
aws_iam_role.viewer                 # IAM 계층  — 정책 0개!
aws_eks_access_entry.viewer         # 인증 계층 — "너는 누구"
aws_eks_access_policy_association   # 인가 계층 — "뭘 할 수 있나"
```

**IAM 사용자가 아니라 역할(role)** 을 씁니다.

| | 사용자 | **역할** ← 사용 |
|---|--------|-----------------|
| 자격증명 | 영구 액세스 키 | 임시 (기본 1시간) |
| 배포 | 키를 만들어 전달 | 빌려 쓰게 허용 |
| 유출 시 | 회수까지 계속 유효 | 만료되면 자동 무효 |

실무에서도 사람에게는 역할을 씁니다. **키를 나눠주지 않아도 되는 게 핵심**입니다.

## 실습 순서

### 1) 생성

```bash
make plan     # "Plan: 3 to add"
make apply
```

### 2) 기준점 — 지금 나는 누구인가

```bash
aws sts get-caller-identity --query Arn --output text
kubectl auth whoami
kubectl auth can-i get nodes        # yes
kubectl auth can-i get secrets      # yes
```

### 3) viewer 역할 빌리기

```bash
ROLE=$(terraform -chdir=terraform output -raw viewer_role_arn)

CREDS=$(aws sts assume-role --role-arn "$ROLE" --role-session-name day4 \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | cut -f1)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | cut -f2)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | cut -f3)
```

> ⚠️ **같은 터미널 창**에서 이어서 실행해야 합니다.

### 4) 신원이 바뀌었는지

```bash
aws sts get-caller-identity --query Arn --output text
#   → arn:aws:sts::...:assumed-role/deepagent-eks-lab-viewer-role/day4
kubectl auth whoami
```

**kubeconfig는 그대로인데 신원만 바뀝니다.** AWS 자격증명이 바뀌니
`aws eks get-token`이 다른 신분증을 발급하기 때문입니다.

### 5) 읽기 / 쓰기 실험

```bash
kubectl get pods -A                     # ✅ 성공
kubectl get nodes                       # ❌ Forbidden — 왜?
kubectl create namespace test-day4      # ❌ Forbidden
kubectl get secrets -A                  # ❌ Forbidden
```

### 6) 복귀

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts get-caller-identity --query Arn --output text   # user/deepagent 복귀
```

### 7) AWS 쪽에서 조회 (두 명령이 나뉜 것에 주목)

```bash
CL=deepagent-eks-lab-cluster
aws eks list-access-entries --cluster-name $CL --output table
aws eks describe-access-entry --cluster-name $CL --principal-arn "$ROLE"
aws eks list-associated-access-policies --cluster-name $CL --principal-arn "$ROLE"
```

### 8) 쿠버네티스 쪽엔 없다는 확인

```bash
kubectl get accessentries                          # 그런 리소스 타입 없음
kubectl get configmap aws-auth -n kube-system      # NotFound
kubectl get clusterrolebindings | grep -i viewer   # 없음 → EKS 인가 웹훅이 처리
```

## 관찰 포인트와 답

### Q1. `get pods`는 되는데 `get nodes`는 안 되는 이유는?

`AmazonEKSViewPolicy`는 쿠버네티스 내장 **`view` ClusterRole**을 씁니다. 직접 확인해보면:

```bash
kubectl get clusterrole view -o yaml | grep -E 'nodes|secrets'
```

```
nodes 포함?   False
secrets 포함? False
pods 포함?    True     (총 47종)
```

리소스는 두 종류입니다.

| 구분 | 예시 | `view`에 포함 |
|------|------|---------------|
| 네임스페이스 리소스 | pods, deployments, services | ✅ |
| **클러스터 범위 리소스** | **nodes**, namespaces, persistentvolumes | ❌ |

`view`는 원래 "개발자에게 자기 네임스페이스 구경 권한 주기" 용도라
노드 같은 인프라 정보는 범위 밖입니다.
`secrets`가 빠진 건 다른 이유 — **의도적 제외**입니다. secret을 읽으면
DB 비밀번호·API 키를 전부 볼 수 있어 "읽기 전용"이라도 위험합니다.

### Q2. `Unauthorized`와 `Forbidden`의 차이는?

| | HTTP | 뜻 | 원인 |
|---|------|-----|------|
| `Unauthorized` | 401 | **누군지 모름** | Access Entry 없음, 토큰 무효 |
| `Forbidden` | 403 | **누군지 알지만 권한 없음** | Access Entry는 있는데 정책 부족 |

실습에서 본 메시지가 결정적입니다.

```
Error from server (Forbidden): nodes is forbidden:
User "arn:aws:sts::...:assumed-role/deepagent-eks-lab-viewer-role/day4" cannot list...
```

**내 신원을 정확히 알고 있습니다.** 몰랐다면 이름을 못 적었겠죠.
①STS 검증 → ②Access Entry 번역까지 전부 성공했고 ③RBAC에서만 막힌 것입니다.

> 🔧 디버깅 팁: `Unauthorized` = **Access Entry가 없다**,
> `Forbidden` = **정책이 부족하다**. 원인이 완전히 다릅니다.

### Q3. viewer 역할엔 IAM 정책이 0개인데 어떻게 들어왔나?

```bash
aws iam list-attached-role-policies --role-name deepagent-eks-lab-viewer-role
# → 비어 있음
```

**AWS 권한이 필요 없기 때문**입니다. `aws eks get-token`은:

```
1. GetCallerIdentity 요청을 만든다
2. 내 자격증명으로 서명한다     ← 로컬 계산. AWS 호출 없음
3. 서명된 URL을 출력한다
```

**AWS API를 한 번도 부르지 않습니다.** 권한 검사 대상 자체가 없습니다.
게다가 `GetCallerIdentity`는 모든 IAM 주체가 무조건 호출 가능합니다 —
자기가 누구인지 묻는 데 허가는 필요 없으니까요.

**"AWS 권한 ≠ 쿠버네티스 권한"의 가장 선명한 증명**입니다.
반대도 성립합니다 — `AdministratorAccess`가 있어도 Access Entry가 없으면 못 들어옵니다.

> 단, `aws eks update-kubeconfig`는 `eks:DescribeCluster`를 실제로 호출하므로
> IAM 권한이 필요합니다. 실습에서 기존 kubeconfig를 재사용한 이유입니다.

### Q4. 노드까지 보게 하려면?

`policy_arn`을 바꾸면 됩니다.

```hcl
policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
```

읽기 계열 정책 세 가지:

| 정책 | 대략적 범위 |
|------|-------------|
| `AmazonEKSViewPolicy` | 네임스페이스 리소스만 (secrets·nodes 제외) |
| `AmazonEKSAdminViewPolicy` | 클러스터 범위 포함, 더 넓은 읽기 |
| `AmazonEKSSecretReaderPolicy` | secret 읽기 전용 |

**이름만 믿지 말고 실제로 확인하세요.** `policy_arn`을 바꿔 `make apply` 후
`kubectl auth can-i get nodes`를 다시 돌리면 5분이면 검증됩니다.

다른 방법으로, 액세스 정책 대신 `kubernetes_groups`로 그룹에 넣고
직접 만든 `ClusterRole`/`ClusterRoleBinding`을 쓸 수도 있습니다
(Day 3의 노드 역할이 `system:nodes`로 그렇게 동작합니다).

## 범위를 더 좁히려면

오늘은 클러스터 전체 읽기였습니다. 네임스페이스 단위로도 조일 수 있습니다.

```hcl
access_scope {
  type       = "namespace"
  namespaces = ["dev"]
}
```

"이 팀은 `dev` 네임스페이스만" 같은 실무 요구가 여기서 처리됩니다.

## 덤: 엿보이는 관리형 서비스의 내부

```bash
kubectl get clusterroles | grep '^eks:'
```

`eks:node-manager`, `eks:addon-manager`, `eks:network-policy-controller` 등
**15개쯤 나옵니다.** 우리가 만들지 않았지만 컨트롤플레인이 이 권한들로
노드를 관리하고 애드온을 설치합니다. 관리형 서비스가 내부에서 무엇을 하는지
엿보이는 지점입니다.

## 비용 메모

- **오늘 추가분 비용: $0** — IAM 역할, Access Entry, 액세스 정책 모두 무료입니다.
- 다만 Day 1~3의 인프라는 계속 돌아갑니다 (시간당 ≈ $0.26).
- 실습이 끝나면 **`make destroy`**.

## 다음 (Day 5)

Phase 0(기반)이 끝났습니다. 네트워크 → 컨트롤플레인 → 노드 → 접근 제어까지
갖췄으니, 드디어 **파드를 띄웁니다.**
Namespace / Deployment / Service를 배포하고 `kubectl`로 관찰합니다.
