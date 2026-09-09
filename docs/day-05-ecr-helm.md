# Day 5 — ECR + Helm으로 내 앱 배포

> 목표: 공개 이미지가 아니라 **내가 만든 이미지와 차트**를 ECR에 올리고 EKS에서 돌린다.
> 기본 오브젝트(Deployment/Service)는 이미 아는 것으로 보고, **배포 경로** 자체에 집중한다.

## 오늘의 경로

```
  내 맥북 (arm64)                AWS
  ┌──────────────┐
  │ app/         │  docker build
  │  main.py     │ ─────────────► 이미지 (60.5 MB)
  │  Dockerfile  │                    │ docker push
  └──────────────┘                    ▼
                              ┌──────────────────┐
  ┌──────────────┐            │ ECR              │
  │ k8s/charts/  │ helm       │  deepagent-app   │ 이미지
  │  Chart.yaml  │ package    │  charts/         │ 차트 (2.4 KB)
  │  templates/  │ ─────────► │   deepagent-app  │
  └──────────────┘ helm push  └──────────────────┘
                                       │ helm install oci://...
                                       ▼
                              ┌──────────────────┐
                              │ EKS (노드 arm64) │  ← 노드가 ECR에서 pull
                              │  파드 × 2 (AZ 분산)│
                              └──────────────────┘
```

## 왜 ECR과 차트를 Terraform 밖에 두는가

`docs/../CLAUDE.md`의 "Terraform 바깥에 두는 리소스"에 적힌 대로,
**ECR 리포지토리는 `destroy` 대상이 아닙니다.**

- 이미지·차트는 매 세션 재빌드/재푸시하기 번거롭습니다
- ECR 비용은 GB당 월 $0.10, 이미지가 작아 **월 1센트 수준**
- state 버킷과 같은 이유 — 인프라를 껐다 켜도 살아남아야 하는 것

태그 없는 이미지는 14일 뒤 자동 삭제되도록 라이프사이클을 걸어뒀습니다.

## 핵심 개념

### 1. ECR 인증 — Day 4의 EKS와 정반대입니다

```bash
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY
```

Day 4의 `aws eks get-token`과 나란히 놓으면 차이가 선명합니다.

| | `eks get-token` (Day 4) | **`ecr get-login-password`** |
|---|---|---|
| AWS API 호출 | ❌ 로컬 서명만 | ✅ **실제 호출** |
| 필요 IAM 권한 | **없음** | **`ecr:GetAuthorizationToken`** |
| 결과물 | 60초 presigned STS URL | **12시간 암호화 토큰** |
| 검증 주체 | STS | ECR |

직접 확인해보면 명확합니다. IAM 정책이 **0개**인 viewer 역할(Day 4에서 만든 것)로 둘을 시도하면:

```
aws eks get-token          → ✅ 성공 (권한 0인데도 됨)
aws ecr get-login-password → ❌ AccessDeniedException:
     ... is not authorized to perform: ecr:GetAuthorizationToken
```

**EKS 쪽이 특이한 경우이고, ECR이 오히려 일반적인 AWS 패턴입니다.**

#### `--username AWS`는 고정값입니다

실제 신원은 비밀번호(토큰) 안에 들어 있습니다. 토큰을 뜯어보면:

```
길이       : 1844자
앞부분     : eyJwYXlsb2FkIjoibmNp...
디코딩하면 : {"payload":"nciTlrpo8aNmK7BY8PdpT4EL0r5XsJtm..."}
```

AWS만 열 수 있는 봉인된 자격증명입니다.

#### ARN은 자격증명이 아닙니다 — 흔한 오해

```
arn:aws:iam::590184068466:user/deepagent
```

이건 **명찰이지 신분증이 아닙니다.** 공개돼도 무해하고 실제로 문서 곳곳에 적혀 있습니다.
**남의 ARN을 안다고 그 사람이 될 수는 없습니다.**

| | ARN | 토큰 |
|---|-----|------|
| 성격 | **이름** (누구인지 가리킴) | **증명** (본인임을 입증) |
| 공개돼도 되나 | ✅ | ❌ 유출 시 사칭 가능 |
| 만료 | 없음 | 12시간 |

인증은 "이름을 대는 것"이 아니라 "증명을 제시하는 것"입니다.

#### 토큰은 어디 저장되나 — macOS 키체인

`~/.docker/config.json`을 열어보면 `"credsStore": "desktop"`만 있고 실제 값이 없습니다.

| | 키체인 미사용 | **키체인 사용 (현재)** |
|---|--------------|----------------------|
| 저장 위치 | `~/.docker/config.json` | macOS 키체인 |
| 형식 | **base64** | 암호화 |
| 위험 | ⚠️ base64는 암호화가 아님 — 한 줄로 복원 | 맥 로그인 인증 필요 |

키체인을 안 쓰면 그 파일을 읽는 누구나 12시간 동안 ECR에 push할 수 있습니다.
dotfiles 리포에 실수로 커밋되면 그대로 유출입니다.

### 2. ARN 구조 읽기

```
arn : aws : iam :: 590184068466 : user/deepagent
 │     │     │   │       │              │
 │     │     │   │       │              └─ 리소스 (타입/이름)
 │     │     │   │       └──────────────── 계정 ID (12자리)
 │     │     │   └──────────────────────── 리전 ← IAM은 글로벌이라 비어 있음
 │     │     └──────────────────────────── 서비스
 │     └────────────────────────────────── 파티션 (aws / aws-cn / aws-us-gov)
 └──────────────────────────────────────── 고정 접두사
```

우리 계정의 실제 ARN을 나란히 놓으면 규칙이 보입니다.

```
arn:aws:iam::590184068466:user/deepagent                    ← 리전 비어 있음 (글로벌)
arn:aws:iam::590184068466:role/deepagent-eks-lab-node-role  ← 리전 비어 있음
arn:aws:eks:ap-northeast-2:590184068466:cluster/deepagent-eks-lab-cluster
arn:aws:ecr:ap-northeast-2:590184068466:repository/deepagent-app
arn:aws:s3:::deepagent-eks-tfstate                          ← 리전·계정 둘 다 비어 있음
```

S3는 **버킷 이름이 전 세계에서 유일**해서 리전과 계정이 모두 생략됩니다.
Day 0에서 버킷 이름 중복을 확인해야 했던 이유와 같은 사실입니다.

### 3. 아키텍처 정합성 — Graviton으로 맞췄습니다

개발 머신이 Apple Silicon(arm64)이라 **노드도 Graviton(t4g, arm64)** 으로 전환했습니다.

| | t3.medium (이전) | **t4g.medium (현재)** |
|---|---|---|
| 아키텍처 | x86_64 | **arm64** |
| vCPU / 메모리 | 2 / 4 GiB | 2 / 4 GiB (동일) |
| 서울 온디맨드 | $0.052/h | **$0.0416/h** (-20%) |

얻는 것:
- **`docker build --platform linux/amd64`가 불필요** — 그냥 빌드하면 맞음
- 크로스 컴파일이 아닌 네이티브 빌드라 더 빠름
- 20% 저렴

잃는 것:
- 드물게 **arm64 빌드가 없는 서드파티 이미지**를 만날 수 있음
  (LB Controller·EBS CSI·metrics-server·Cilium 등 주요 컴포넌트는 모두 지원)

> ⚠️ **아키텍처가 어긋나면** 파드가 `exec format error`로 CrashLoopBackOff에 빠집니다.
> 이미지의 아키텍처는 **빌드한 머신을 따라가기** 때문입니다.
> 노드가 x86이라면 반드시 `--platform linux/amd64`로 빌드해야 합니다.
> `ami_type`과 `instance_types`가 어긋나는 실수를 막으려고 `variables.tf`에
> `validation` 블록을 넣어뒀습니다.

### 4. Helm 차트를 ECR에 올린다 (OCI 아티팩트)

ECR은 컨테이너 이미지뿐 아니라 **OCI 아티팩트**를 저장할 수 있어서 Helm 차트도 들어갑니다.

```bash
helm package k8s/charts/deepagent-app --destination /tmp
helm push /tmp/deepagent-app-0.1.0.tgz oci://$REGISTRY/charts
helm install myapp oci://$REGISTRY/charts/deepagent-app --version 0.1.0 -n demo --create-namespace
```

- **`helm registry login`이 따로 필요 없습니다** — `docker login`이 만든 자격증명을 helm이 그대로 씁니다
- ECR은 리포지토리를 자동 생성하지 않으므로 `charts/deepagent-app` 리포를 미리 만들어야 합니다
- 차트 크기는 2.4 KB (이미지는 60.5 MB)

#### `version` vs `appVersion`

| 필드 | 뜻 | 올려야 할 때 |
|------|-----|-------------|
| `version` | **차트 자체**의 버전 | 템플릿이 바뀌었을 때 |
| `appVersion` | 담고 있는 **앱**의 버전 | 이미지가 바뀌었을 때 |

ECR에 푸시될 때 아티팩트 태그가 되는 건 **`version`** 쪽입니다.

### 5. push해도 자동 배포되지 않습니다

**쿠버네티스는 레지스트리를 감시하지 않습니다.**

```
docker push  →  ECR에 이미지가 놓임
                     ↓
              (아무 일도 안 일어남)
                     ↓
        내가 명시적으로 배포를 지시해야 함
```

이미지를 pull하는 시점은 **파드가 새로 생성될 때뿐**입니다.

#### ⚠️ `imagePullPolicy: IfNotPresent`의 함정

```
같은 태그(0.1.0)로 이미지를 새로 push
        ↓
kubectl rollout restart 로 파드 재생성
        ↓
노드: "0.1.0? 이미 캐시에 있는데" → 옛 이미지 사용 😱
```

**해결은 태그를 매번 올리는 것**입니다 (`0.1.1`, `0.1.2`, 커밋 해시…).
`latest`가 위험하다고 하는 이유가 이것입니다 — 무엇이 돌고 있는지 아무도 확신할 수 없어집니다.

자동 배포를 원하면 **컨트롤러를 따로 설치**해야 합니다.

| 도구 | 방식 |
|------|------|
| CI 파이프라인 | 빌드 → push → `helm upgrade`까지 CI가 실행 |
| **ArgoCD / Flux** | Git을 감시. 매니페스트가 바뀌면 자동 배포 (**GitOps**) |
| ArgoCD Image Updater | 레지스트리를 감시해 새 태그를 자동 반영 |

→ 심화 주제의 **GitOps**에서 다룹니다.

## 실습 순서

```bash
export REGION=ap-northeast-2
export REGISTRY=590184068466.dkr.ecr.$REGION.amazonaws.com
export VERSION=0.1.0

# 1) ECR 로그인 (12시간 유효)
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY

# 2) 빌드 — 노드가 arm64라 --platform 불필요
docker build --build-arg VERSION=$VERSION -t $REGISTRY/deepagent-app:$VERSION ./app
docker image inspect $REGISTRY/deepagent-app:$VERSION --format '{{.Architecture}}'   # arm64

# 3) 이미지 푸시
docker push $REGISTRY/deepagent-app:$VERSION

# 4) 차트 패키징 & 푸시
helm package k8s/charts/deepagent-app --destination /tmp
helm push /tmp/deepagent-app-$VERSION.tgz oci://$REGISTRY/charts

# 5) ECR에서 설치
helm install myapp oci://$REGISTRY/charts/deepagent-app --version $VERSION \
  --namespace demo --create-namespace

# 6) 확인
kubectl get pods -n demo -o wide
kubectl port-forward -n demo svc/myapp-deepagent-app 8080:80
curl -s localhost:8080 | jq
```

## 관찰 포인트와 실제 결과

### 1. 파드가 AZ에 분산됐나

```
파드                                    노드              AZ
myapp-...-brsrv   ip-10-0-50-225   ap-northeast-2c
myapp-...-q48x2   ip-10-0-42-154   ap-northeast-2a
```

✅ 정확히 하나씩. 차트의 `topologySpreadConstraints`(`maxSkew: 1`, `topologyKey: zone`)가
Day 1에서 서브넷을 2a/2c로 나눈 구조 위에서 동작한 결과입니다.

### 2. 응답이 말해주는 것

```json
{
  "message": "hello from EKS",
  "version": "0.1.0",
  "pod": "myapp-deepagent-app-5c78764c7b-brsrv",
  "node": "ip-10-0-50-225.ap-northeast-2.compute.internal",
  "podIP": "10.0.61.87",
  "arch": "aarch64"
}
```

- **`arch: aarch64`** → Graviton 전환이 이미지 빌드까지 끝까지 반영됨
- **`podIP: 10.0.61.87`** → **VPC 대역**입니다. 오버레이 네트워크가 아니라
  파드가 진짜 VPC IP를 받았다는 뜻 — VPC CNI의 특징이고 Day 6의 주제입니다
- `node`, `podIP`는 파드가 스스로 알 수 없어 **downward API**로 주입받았습니다

### 3. 노드가 ECR에서 pull한 증거

```
Normal  Pulling  kubelet  Pulling image "590184068466.dkr.ecr.ap-northeast-2.amazonaws.com/deepagent-app:0.1.0"
Normal  Pulled   kubelet  Successfully pulled ... in 2.656s. Image size: 63408949 bytes
Normal  Created  kubelet  Container created
Normal  Started  kubelet  Container started
```

**Day 3에서 노드 역할에 붙인 `AmazonEC2ContainerRegistryReadOnly` 정책이 실제로 쓰인 순간**입니다.
그 정책이 없었다면 `ImagePullBackOff`가 났습니다.
Day 3 문서의 "정책 3개 — 각각 없으면 무엇이 깨지는가" 표의 ③번이 여기서 증명됩니다.

### 4. 이미지 크기

| | 크기 |
|---|------|
| 이미지 (python:3.13-slim 기반) | 60.5 MB |
| 차트 | 2.4 KB |

`python:slim` + venv 멀티스테이지로 줄인 결과입니다.
(참고: 의존성 없는 Go를 `scratch`에 담으면 ~7MB까지 내려가지만,
Python은 런타임이 필요해 이 정도가 현실적인 하한입니다)

## 보안 관점에서 넣어둔 것들

차트 템플릿에 이미 반영돼 있습니다.

| 설정 | 이유 |
|------|------|
| `USER 65534:65534` (Dockerfile) | 비루트 실행 |
| `readOnlyRootFilesystem: true` | 침해 시 파일을 못 심게 |
| `/tmp`만 emptyDir로 열기 | 읽기 전용으로 잠갔으니 Python이 쓸 곳은 하나 필요 |
| `capabilities: drop [ALL]` | 리눅스 케이퍼빌리티 전부 제거 |
| `allowPrivilegeEscalation: false` | 권한 상승 차단 |
| `PYTHONDONTWRITEBYTECODE=1` | `.pyc`를 안 만들어 읽기 전용과 충돌 방지 |
| ECR `scanOnPush=true` | 푸시 시 취약점 스캔 |

## 비용 메모

- **오늘 추가되는 시간당 비용: $0** — 이미 떠 있는 노드 위에서 돕니다
- **ECR**: GB당 월 $0.10 → 60MB 이미지면 **월 1센트 미만**. 같은 리전 내 pull은 무료
- Graviton 전환으로 노드가 싸져서 **시간당 합계 $0.26 → $0.24**
  (컨트롤플레인 $0.10 + 노드 $0.083 + NAT $0.05 + 퍼블릭 IPv4 $0.005)
- 세션 종료 시 `make destroy`. **ECR은 남으므로** 다음 세션엔 `helm install`만 하면 됩니다

## 정리

```bash
helm uninstall myapp -n demo
kubectl delete ns demo
```

## 다음 (Day 6)

`podIP`가 왜 `10.0.x.x`인지 — **VPC CNI**의 원리를 봅니다.
파드가 VPC IP를 받는 구조, ENI/IP 워밍풀, 그리고 그 대가로 무엇을 얻는지
(파드 단위 보안그룹, ALB `target-type: ip`, Flow Logs 가시성).
그 다음 Day 6-1에서 **Cilium으로 CNI를 교체**하면 무엇을 잃는지 확인합니다.
