# Day 3 — 노드 그룹 (워커 노드)

> 목표: 파드가 실제로 돌아갈 **컴퓨트**를 만들고 클러스터에 조인시킨다.
> Day 2가 "두뇌"였다면 오늘은 "근육"이다.

## 오늘의 결정적 차이: 진짜 내 EC2가 생깁니다

Day 2에서 컨트롤플레인을 만들었지만 `aws ec2 describe-instances`는 **0개**였습니다.
AWS 계정에서 돌아가기 때문입니다.

**오늘은 다릅니다.** 노드는 내 계정의, 내 VPC의, 내가 요금을 내는 EC2입니다.

```
        내 AWS 계정                         AWS 운영 영역
  ┌────────────────────────────┐        ┌──────────────────┐
  │  VPC                       │        │  컨트롤플레인     │
  │  ┌──────────────────────┐  │        │  (Day 2)         │
  │  │ private subnet 2a    │  │        │                  │
  │  │  ├ EKS ENI ──────────┼──┼───────►│                  │
  │  │  └ 🖥️ 노드 (t3.medium)│  │◄──────►│                  │
  │  ├──────────────────────┤  │        └──────────────────┘
  │  │ private subnet 2c    │  │
  │  │  ├ EKS ENI           │  │
  │  │  └ 🖥️ 노드 (t3.medium)│  │
  │  └──────────────────────┘  │
  └────────────────────────────┘
       ↑ 오늘 추가되는 것 (내 EC2!)
```

## 오늘 만드는 것 — 5개

```
┌─ IAM 역할 ─────────────────────────┐
│ deepagent-eks-lab-node-role        │  ① 노드가 쓸 역할
│   ├ AmazonEKSWorkerNodePolicy      │  ②   클러스터 조인
│   ├ AmazonEKS_CNI_Policy           │  ③   파드에 IP 할당
│   └ AmazonEC2ContainerRegistryRO   │  ④   이미지 pull
└────────────────────────────────────┘
                 ↓
┌─ 관리형 노드 그룹 ─────────────────┐
│ t3.medium × 2, 프라이빗 서브넷      │  ⑤ 실제 EC2
└────────────────────────────────────┘
```

## 핵심 개념

### 1. 두 IAM 역할의 대비 (오늘의 하이라이트)

Day 2에서 "신뢰 정책이 `eks.amazonaws.com`인 이유"를 설명하며 예고한 지점입니다.

| | 클러스터 역할 (Day 2) | **노드 역할 (오늘)** |
|---|---|---|
| 신뢰 서비스 | `eks.amazonaws.com` | **`ec2.amazonaws.com`** |
| 누가 빌리나 | EKS 서비스 | **내 EC2 인스턴스** |
| 무엇을 하나 | 내 VPC 리소스 조작 | 클러스터 조인, 이미지 pull |
| 정책 수 | 1개 | 3개 |

신뢰 서비스가 다른 이유는 단순합니다. **이번엔 진짜 EC2가 이 역할을 빌려 쓰기 때문**입니다.
EC2가 역할을 사용하는 방식을 **인스턴스 프로파일**이라 부르는데,
관리형 노드 그룹에서는 EKS가 알아서 만들어 붙여줍니다.

> Day 2에서 "권한은 무엇 위에서 실행되는가가 아니라 무엇을 조작하는가로 결정된다"고 했는데,
> 오늘 역할은 **실행 주체와 조작 대상이 둘 다 EC2**라 헷갈리지 않습니다.

### 2. 정책 3개 — 각각 없으면 무엇이 깨지는가

| 정책 | 역할 | 없으면 |
|------|------|--------|
| `AmazonEKSWorkerNodePolicy` | 클러스터 조인, 컨트롤플레인 통신 | 노드가 아예 조인 안 됨 (`NotReady`) |
| `AmazonEKS_CNI_Policy` | 파드에 VPC IP 할당 | 노드는 뜨는데 **파드가 Pending에서 멈춤** |
| `AmazonEC2ContainerRegistryReadOnly` | ECR에서 이미지 pull | CoreDNS 등 필수 애드온이 `ImagePullBackOff` |

두 번째가 특히 함정입니다. **노드는 Ready인데 파드만 안 뜨는** 증상이라
원인을 CNI 권한에서 찾기까지 시간이 걸립니다.

### 3. 노드 그룹 3가지 방식

| 방식 | 누가 관리 | 특징 |
|------|-----------|------|
| **관리형 노드 그룹** ← 오늘 | EKS가 EC2 생성·조인·업그레이드 | 노드가 내 계정에 보임. 균형이 좋음 |
| 자체 관리 노드 | 내가 ASG·AMI·부트스트랩 전부 | 자유롭지만 할 일이 많음 |
| Fargate | AWS 완전 관리 | 노드 자체가 없음. 비싸고 제약 많음(DaemonSet 불가) |

학습에는 관리형이 적합합니다. "노드가 어떻게 조인되는가"는 관찰하면서
AMI 선택·부트스트랩 스크립트 같은 잡일은 EKS에 맡길 수 있습니다.

### 4. 노드는 어떻게 클러스터에 조인하는가

관리형 노드 그룹이 대신 해주지만, 내부에서 벌어지는 일은 이렇습니다.

```
1. EKS가 오토스케일링 그룹(ASG)을 만들고 EC2를 띄움
2. 부팅 시 부트스트랩 스크립트 실행 → 클러스터 엔드포인트/인증서를 받아 kubelet 설정
3. kubelet이 노드 역할의 자격증명으로 API 서버에 "저 조인할게요" 요청
4. 컨트롤플레인이 IAM 신원을 확인하고 승인 → Node 오브젝트 생성
5. VPC CNI(DaemonSet)가 노드에 ENI를 붙이고 파드용 IP 풀 확보
6. 노드 상태 Ready ✅
```

3번에서 **IAM 신원이 쿠버네티스 권한으로 변환**됩니다. 이 매핑이 Day 4의 주제입니다.
5번에서 파드가 VPC IP를 받는 구조가 Day 6의 주제입니다.

### 5. AL2023과 온디맨드

- **`ami_type = "AL2023_x86_64_STANDARD"`** — Amazon Linux 2023.
  EKS 1.33부터 구형 AL2는 지원되지 않습니다.
- **`capacity_type = "ON_DEMAND"`** — Spot이 70%쯤 싸지만 AWS가 언제든 회수합니다.
  오늘은 "조인 원리"에 집중하려고 예측 가능한 쪽을 택했습니다.
  Spot은 이후 심화 주제(비용 최적화)에서 다룹니다.

## 실습 순서

```bash
make plan     # "Plan: 5 to add" — Day 1·2의 17개는 그대로
make apply    # ⏱️ 3~5분 (컨트롤플레인보다는 빠름)
```

생성 후 확인:

```bash
# ① 이제 내 EC2가 보입니다 (Day 2에서는 0개였음!)
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,AZ:Placement.AvailabilityZone,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}" \
  --output table
#   → PublicIP가 비어 있는지 확인! 프라이빗 서브넷이라 공인 IP가 없습니다.

# ② 노드 그룹 상태
aws eks describe-nodegroup --cluster-name deepagent-eks-lab-cluster \
  --nodegroup-name deepagent-eks-lab-ng \
  --query "nodegroup.{Status:status,Type:instanceTypes,AMI:amiType,Scaling:scalingConfig}" --output json

# ③ EKS가 만든 ASG (내 코드엔 없는데 생겼습니다)
terraform -chdir=terraform output node_asg_names
```

## 관찰 포인트

1. 노드 2대가 **서로 다른 AZ**에 배치됐나요? 왜 그렇게 됐을까요?
2. 노드에 **공인 IP가 없는데** 어떻게 컨테이너 이미지를 받아올까요? (힌트: Day 1의 NAT)
3. 노드의 ENI는 어느 서브넷에 있나요? Day 2의 컨트롤플레인 ENI와 같은 서브넷인가요?
4. `node_asg_names` 출력의 ASG는 우리가 코드로 만들지 않았는데 어디서 왔을까요?
5. 지금 `kubectl get nodes`를 하면? (여전히 실패 — kubeconfig가 없습니다. Day 4의 주제)
6. 노드 역할의 신뢰 서비스를 콘솔에서 확인하고, 클러스터 역할과 비교해 보세요.

## 비용 메모

- **t3.medium × 2 ≈ 시간당 $0.10 안팎** (리전·시점에 따라 다르므로 요금 페이지 확인)
- EBS 20GB × 2 = 40GB — 시간당으로 환산하면 미미합니다
- **오늘부터 시간당 합계 ≈ $0.26**
  (컨트롤플레인 $0.10 + 노드 $0.10 + NAT $0.05 + 퍼블릭 IPv4 $0.005)
- 더 줄이려면 `terraform.tfvars`의 `node_desired_size`를 **1**로 낮추면 됩니다.
  대신 AZ 분산(관찰 포인트 1번)을 볼 수 없습니다.
- **`make destroy`는 이제 더 중요합니다.** 하루 종일 켜두면 약 $6입니다.

## 다음 (Day 4)

노드까지 준비됐지만 아직 **내 손으로 클러스터를 조작할 수 없습니다.**
`kubectl get nodes`가 실패하는 이유(kubeconfig 부재)를 해결하고,
IAM 신원이 쿠버네티스 권한으로 변환되는 구조(Access Entries)를 봅니다.
오늘 조인 과정 3번에서 벌어진 일의 정체입니다.
