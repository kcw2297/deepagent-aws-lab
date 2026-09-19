# Day 10 — 오토스케일링 (HPA + Cluster Autoscaler)

> 목표: **부하가 늘면 파드와 노드가 알아서 늘고, 줄면 알아서 줄게** 한다.
> Day 3에서 "실행 장치(ASG)는 있는데 두뇌(오토스케일러)가 없다"고 한 곳에 두뇌를 끼웁니다.
> Karpenter는 뒤로 미루고, ASG를 그대로 쓰는 **Cluster Autoscaler**를 먼저 제대로 이해합니다.

## 오늘의 구조

```
                 [컨트롤 플레인]                               [AWS]
  metrics-server ──(파드 CPU)──► HPA (kube-controller-manager 안)
                                  │ Deployment replicas 1→2→4→8→10
                                  ▼                         쿠버네티스 API만 호출
                        ReplicaSet → 파드 생성
                                  ▼
                        스케줄러: requests 자리 없음 → Pending
                                  ▼
  [kube-system]         Cluster Autoscaler (파드, Helm)
                                  │ Pending 감지 → "노드 1대면 들어간다" 시뮬레이션
                                  │ Pod Identity로 받은 권한
                                  └──────────────────────────────►  ASG SetDesiredCapacity(3)
                                                                         │
                                                                         ▼
                                                                     EC2 1대 시작
                        kubelet 등록 → Ready ◄──────────────────────────────┘
                                  ▼
                        스케줄러: Pending 파드를 새 노드에 배치
```

**HPA와 CA는 서로 직접 대화하지 않습니다.** 둘을 잇는 건 **Pending 파드** 하나뿐입니다.

## 핵심 개념

### 1. 확장은 두 층이다 — HPA는 파드, CA는 노드

| | HPA | Cluster Autoscaler |
|---|---|---|
| 늘리는 것 | **파드** 개수 (Deployment `replicas`) | **노드** 개수 (ASG `desired`) |
| 판단 근거 | 파드의 CPU 사용률 (metrics-server) | **Pending 파드** (스케줄 실패) |
| 어디서 도나 | 컨트롤 플레인 (`kube-controller-manager`) | `kube-system`의 **일반 파드** |
| 호출하는 API | 쿠버네티스 API만 | 쿠버네티스 API + **AWS API** |
| AWS 권한 | 필요 없음 | 필요 (Pod Identity) |
| 설치 | 쿠버네티스 내장 (metrics-server만 추가) | Helm |

**HPA는 노드를 모르고, CA는 CPU를 모릅니다.** 각자 자기 층만 봅니다.

그래서 이런 일이 생깁니다:
- HPA 없이 `kubectl scale --replicas=20`으로 늘려도 CA는 똑같이 노드를 늘립니다
- HPA가 파드를 늘려도 기존 노드에 다 들어가면 CA는 아무것도 안 합니다
  (실습에서 replicas 4개까지는 CA 로그에 `No unschedulable pods`만 찍혔습니다)

### 2. Cluster Autoscaler의 정의

> **스케줄되지 못한 파드가 있으면 노드를 늘리고, 불필요한 노드가 있으면 줄이는 컴포넌트**

| 특징 | 의미 |
|---|---|
| **Pending 파드가 트리거** | CPU 사용률을 보지 않습니다. "자리가 없다"는 사실만 봅니다 |
| **requests 기준 시뮬레이션** | 스케줄러 로직을 내장해 "노드를 추가하면 이 파드가 들어가는가"를 계산합니다 |
| **노드 그룹 단위 조작** | EC2를 직접 만들지 않습니다. ASG의 숫자만 바꾸고 인스턴스는 ASG가 만듭니다 |

스케줄러 로직을 내장하기 때문에 **CA 버전은 쿠버네티스 마이너 버전과 맞춥니다.**
차트 9.59.0의 기본 이미지는 v1.35.0이라 `image.tag: v1.36.1`로 올렸습니다.

### 3. "사용률"은 노드가 아니라 **파드의 requests 대비**다

HPA가 보여준 `cpu: 100%/50%`는 노드 CPU가 아닙니다.

```
HPA 사용률 = 파드 실제 사용량 / 파드 requests = 400m / 400m = 100%
```

실습 중 노드 하나에 stress 3개(1200m)가 돌았지만 allocatable이 약 1930m이라
노드 CPU 사용은 **60% 정도**였습니다. 그런데도 Pending이 생겼습니다.

**"노드가 꽉 찼다" = 실제 사용량이 아니라 requests 합계가 찼다**는 뜻입니다.
스케줄러도 CA도 requests만 봅니다. 그래서 **requests가 없는 파드는 오토스케일링이 제대로 동작하지 않습니다.**

### 4. HPA는 두 배씩만 늘어난다 — limit 때문에

```
desired = ceil(현재 replicas × 현재 사용률 / 목표)
  1 × 100/50 = 2
  2 × 100/50 = 4
  4 × 100/50 = 8
  8 × 100/50 = 16 → maxReplicas 10
```

`limits.cpu = requests.cpu = 400m`라 루프가 CPU를 더 쓰고 싶어도 스로틀링되어
사용률이 100%에서 멈춥니다. 그래서 한 번에 10개로 뛰지 않고 **단계마다 2배**입니다.
단계 사이에는 새 파드 메트릭 수집(15s) + HPA 재계산(15s)이 걸립니다.

### 5. metrics-server — HPA의 전제 조건

- kubelet에서 파드/노드 CPU·메모리를 **15초마다** 긁어 **최신 값 하나만 메모리에** 둡니다 (이력 없음)
- `APIService v1beta1.metrics.k8s.io`로 등록돼, `kubectl top`과 HPA가 **쿠버네티스 API처럼** 조회합니다
- 관리형 애드온(`aws_eks_addon.metrics_server`)이고 AWS 권한이 필요 없습니다
- 이력·대시보드는 Day 11(관측성)의 몫입니다

### 6. Terraform과 CA가 `desired_size`를 두고 싸운다 → `ignore_changes`

```
CA        : ASG desired 2 → 3  (실제 인프라 변경)
Terraform : 코드엔 desired_size = 2 → 다음 apply에서 "3을 2로 되돌리겠습니다"
```

이러면 apply할 때마다 CA가 늘린 노드를 Terraform이 지웁니다. 그래서 역할을 나눴습니다.

```hcl
# terraform/eks-nodegroup.tf
lifecycle {
  ignore_changes = [scaling_config[0].desired_size]
}
```

| 값 | 주인 |
|---|---|
| `min_size` / `max_size` | **Terraform** — 경계선 |
| `desired_size` | **CA** — 경계 안에서 움직이는 현재값 |

실습에서 **확장 직후(desired 3)와 축소 직후(desired 2) 모두 `make plan` = `No changes`** 를 확인했습니다.

### 7. 자동 탐색 — 이름이 아니라 태그로 ASG를 찾는다

EKS 관리형 노드 그룹은 ASG에 이 태그를 처음부터 붙여둡니다 (Day 3에서 확인):

```
k8s.io/cluster-autoscaler/enabled                   = true
k8s.io/cluster-autoscaler/deepagent-eks-lab-cluster = owned
```

values에 `autoDiscovery.clusterName`만 주면 CA가 이 태그로 ASG를 찾습니다.
ASG 이름(`eks-deepagent-eks-lab-ng-bcd05bc2-...`)은 EKS가 붙이는 랜덤 이름이라 적을 수 없습니다.

```
CA 로그: Registering ASG eks-deepagent-eks-lab-ng-bcd05bc2-2ff3-9e2f-f872-3e30f0c3d42b
```

### 8. IAM — 같은 태그를 **권한 조건**으로도 쓴다

| Statement | 액션 | 범위 |
|---|---|---|
| `ReadOnly` | `Describe*`, `eks:DescribeNodegroup` 등 | 전체 |
| `ScaleOnlyOwnedAsg` | `SetDesiredCapacity`, `TerminateInstanceInAutoScalingGroup` | **위 두 태그가 붙은 ASG만** |

조건이 없으면 이 파드가 계정의 **아무 ASG나** 늘리고 줄일 수 있습니다.
태그는 탐색(7번)과 권한 제한(8번)에 **두 번** 쓰입니다.

| Day | 컨트롤러 | 정책 출처 |
|---|---|---|
| 8 | LB Controller | AWS가 준 JSON 파일 |
| 9 | EBS CSI | AWS 관리형 정책 ARN |
| **10** | **Cluster Autoscaler** | **관리형 정책이 없어 직접 작성** — 그래서 조건까지 보입니다 |

Pod Identity 연결은 Day 8과 같은 **별도 `aws_eks_pod_identity_association`**입니다
(Helm 설치라 Day 9처럼 애드온 안에 넣을 수 없습니다).
⚠️ values의 `rbac.serviceAccount.name: cluster-autoscaler`를 비우면 차트가 다른 이름을 만들어
연결과 어긋나고 `AccessDenied`가 납니다.

### 9. 축소 — 네 가지 조건과 제거 절차

CA는 10초마다 노드마다 묻습니다:

```
① requests 사용률 < 50%?                    (scale-down-utilization-threshold, 기본 0.5)
② 파드를 다른 노드로 옮길 수 있나?          (emptyDir, PDB, kube-system 파드 등)
③ ①②가 1분 이상 계속됐나?                   (scale-down-unneeded-time: 1m, 기본 10m)
④ 마지막 확장 후 1분 지났나?                (scale-down-delay-after-add: 1m, 기본 10m)
```

③④는 **실습용으로 1분으로 줄인 값**입니다. 기본 10분은 부하가 잠깐 줄었다고
노드를 지웠다 다시 늘리는 **진동**을 막기 위한 것이라 운영에선 기본값을 씁니다.

제거는 한 번에 하지 않습니다:

```
1. taint ToBeDeletedByClusterAutoscaler:NoSchedule   → 새 파드 차단
2. 파드 evict (DaemonSet 제외)
3. TerminateInstanceInAutoScalingGroup(ShouldDecrementDesiredCapacity=true)
   → "이 인스턴스"를 지우고 desired도 1 줄임
4. 노드 객체 삭제
```

`SetDesiredCapacity(2)`로 줄이면 **ASG가 지울 인스턴스를 스스로 고릅니다.**
CA가 비워둔 노드가 아니라 파드가 잔뜩 있는 노드가 죽을 수 있습니다.
그래서 축소에는 **특정 인스턴스를 지정하는 API**가 따로 필요합니다.

### 10. emptyDir이 있는 노드는 축소되지 않는다

설치 직후 CA 로그:

```
ip-10-0-44-58 ... unremovable: pod with local storage present
ip-10-0-56-14 ... unremovable: pod with local storage present
```

`--skip-nodes-with-local-storage=true`(기본값) 때문입니다. emptyDir은 노드 디스크에 있어서
파드를 옮기면 **데이터가 사라지므로** CA가 보수적으로 막습니다.

| 파드 | emptyDir |
|---|---|
| metrics-server | `--cert-dir=/tmp` |
| ebs-csi-controller | 소켓 디렉터리 |

그래서 min=1이지만 **기존 2대는 줄지 않고, 확장으로 생긴 노드만** 줄어듭니다.
CA는 로그에 **첫 번째로 걸린 이유만** 남긴다는 것도 확인했습니다
(kube-system 파드 때문일 거라 예측했지만 실제로는 emptyDir이 먼저 걸렸습니다).

## 오늘 만든 것

| 위치 | 내용 |
|---|---|
| `terraform/eks-autoscaling.tf` | metrics-server 애드온, CA IAM 역할·정책·Pod Identity 연결 |
| `terraform/eks-nodegroup.tf` | `lifecycle { ignore_changes = [scaling_config[0].desired_size] }` |
| `terraform/variables.tf` · `terraform.tfvars` | `addon_version_metrics_server = "v0.9.0-eksbuild.11"` |
| `terraform/outputs.tf` | `cluster_autoscaler_role_arn` |
| `k8s/day10/cluster-autoscaler-values.yaml` | 자동 탐색, 이미지 v1.36.1, SA 이름, 축소 1분 |
| `k8s/day10/stress.yaml` | `scale-demo` 네임스페이스, CPU 400m 부하 Deployment, HPA(1~10, 50%) |
| `Makefile` | `destroy`에 `helm uninstall cluster-autoscaler` 추가 |

## 실습 순서

```bash
# 1) 인프라 — metrics-server, IAM, ignore_changes
make plan && make apply
kubectl top nodes                       # 메트릭이 보이면 metrics-server 정상

# 2) Cluster Autoscaler 설치
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --version 9.59.0 -n kube-system -f k8s/day10/cluster-autoscaler-values.yaml

kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler --tail=100 \
  | grep -i 'eks-deepagent'             # Registering ASG ... 확인

# 3) 부하 — 터미널 4개
kubectl get hpa -n scale-demo -w
kubectl get pods -n scale-demo -o wide -w
kubectl get nodes -w
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler -f --tail=0 \
  | grep -E "Final scale-up plan|Scale-up|Pod .* is unschedulable"

kubectl apply -f k8s/day10/stress.yaml

# 4) 확장 확인
aws autoscaling describe-auto-scaling-groups --region ap-northeast-2 \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'deepagent-eks-lab-ng')].[MinSize,DesiredCapacity,MaxSize]" \
  --output table
make plan                               # No changes

# 5) 축소
kubectl delete -f k8s/day10/stress.yaml
# 몇 분 뒤 kubectl get nodes / ASG / make plan 다시 확인
```

## 실습 결과

### 확장 — Pending부터 배치까지 약 45초

| 시점 | 사건 | 출처 |
|---|---|---|
| 0s ~ 45s | HPA 메트릭 `<unknown>` → `100%/50%` | HPA |
| 60s → 90s → 2m | replicas 1 → 2 → 4 → 8 | HPA |
| 09:22:59 | 노드 2대 requests 소진, `sfhwc`·`vz5qm` **Pending** | pods / `triggered by unschedulable pod appearing` |
| 09:23:09 | **`Final scale-up plan: [{eks-deepagent-eks-lab-ng-... 2->3 (max: 3)}]`** | CA |
| 09:23:09 | `Scale-up: setting group ... size to 3` → `ScaledUpGroup` 이벤트 | CA |
| 2m31s | replicas 8 → 10, `m6hp6`·`hffjt`도 Pending | HPA |
| +30s 전후 | `ip-10-0-59-42` 등록(NotReady) → **11초 뒤 Ready** | nodes |
| 직후 | Pending 4개가 전부 새 노드에 배치 → Running | pods |

`ScaledUpGroup`이 에러 없이 찍혔다 = **Pod Identity → IAM 역할 → 태그 조건부 SetDesiredCapacity**가 모두 동작.

### 로그에서 본 것 — upcoming node

확장을 결정한 바로 다음 루프:

```
Found 24 pods ... 2 unschedulable
2 pods marked as unschedulable can be scheduled.
No unschedulable pods
```

노드가 **아직 뜨지도 않았는데** "스케줄 가능"이라고 합니다.
CA가 **곧 생길 노드(upcoming node)를 시뮬레이션에 포함**시키기 때문입니다.
그래서 노드가 부팅되는 동안 Pending이 4개로 늘어도 4번째 노드를 **중복 요청하지 않았습니다** —
새 노드 1대에 4개가 다 들어간다고 계산했습니다.

### 최종 배치 — 예측보다 많이 들어갔다

```
ip-10-0-44-58 : stress 3개  (기존 노드 — 시스템 파드 requests가 있음)
ip-10-0-56-14 : stress 3개
ip-10-0-59-42 : stress 4개  (새 노드 — DaemonSet 파드만 있어 1개 더 들어감)
```

"max=3이라 일부는 Pending으로 남을 것"이라 예측했지만 **10개 모두 배치**됐습니다.
노드당 수용량은 계산보다 **`kubectl describe nodes`의 `Allocated resources`로 직접 보는 게** 정확합니다.

### 축소 — 새 노드만 빠졌다

`kubectl delete -f k8s/day10/stress.yaml` 후 몇 분 뒤:

```
kubectl get nodes
ip-10-0-44-58   Ready   7h
ip-10-0-56-14   Ready   7h          ← ip-10-0-59-42 사라짐

ASG  min 1 / desired 2 / max 3
make plan → No changes
```

| 노드 | 사용률 | 옮길 수 있나 | 결과 |
|---|---|---|---|
| ip-10-0-44-58 | 낮음 | ❌ emptyDir | 유지 |
| ip-10-0-56-14 | 낮음 | ❌ emptyDir | 유지 |
| **ip-10-0-59-42** | 거의 0 | ✅ DaemonSet만 | **제거** |

## 실습 중 발견한 것 — 롤링 업데이트는 옛 파드도 센다

CA 로그를 보다 coredns 2개가 한 노드에 몰린 걸 발견하고 `kubectl rollout restart`로 흩어보려 했는데,
**반대편 노드에 둘 다 몰렸습니다.**

```
롤아웃 순간
  ip-10-0-44-58 : 옛 coredns 2개 (Terminating 직전, 아직 존재)
  ip-10-0-56-14 : 0개
→ 분산 규칙(k8s-app=kube-dns가 적은 곳으로)이 옛 파드까지 셈
→ 새 파드 2개 모두 56-14로
→ 옛 파드 종료 → 결과: 56-14에만 2개
```

셀렉터가 `k8s-app`만 봐서 옛 버전과 새 버전을 구분하지 못합니다.
해법은 `topologySpreadConstraints.matchLabelKeys: [pod-template-hash]`(같은 버전끼리만 셈)지만,
coredns는 관리형 애드온이라 직접 고쳐도 애드온 갱신 때 덮어써져 손대지 않았습니다.

스케줄링 규칙은 대부분 `IgnoredDuringExecution`이라 **이미 뜬 파드를 다시 배치하지 않는다**는 것도 함께 확인했습니다.

## ⚠️ 정리 — `make destroy`

```
── ① 쿠버네티스 오브젝트 삭제 (Day 8 Gateway, Day 9 PVC)
── ② ALB·EBS 사라질 때까지 대기
── ③ Helm 컨트롤러 제거: LB Controller, Cluster Autoscaler   ← Day 10 추가
── ④ terraform destroy
```

CA가 만든 노드는 **ASG 안의 인스턴스**라서 ALB·EBS와 달리 Terraform state 밖에 남지 않습니다.
노드 그룹이 지워지면 ASG와 함께 사라집니다. CA를 먼저 내리는 건 destroy 도중
CA가 ASG를 건드리지 않게 하려는 것입니다.

## 관찰 포인트

1. HPA가 파드를 4개까지 늘렸을 때 CA 로그는 왜 조용했나?
2. HPA의 `100%`는 무엇 대비인가? 그때 노드 CPU 사용률은 얼마였나?
3. 왜 replicas가 한 번에 10이 되지 않고 2배씩 늘었나?
4. 확장 결정 직후 `can be scheduled`가 뜬 이유는? 그게 없으면 무슨 일이 생기나?
5. 축소에 `SetDesiredCapacity`만으로는 부족한 이유는?
6. min=1인데 왜 2대에서 멈췄나?
7. CA가 desired를 바꿨는데 `make plan`이 `No changes`인 이유는?

## 비용 메모

- metrics-server, CA 파드: **무료** (기존 노드 자원 사용)
- 확장된 노드: t4g.medium **+$0.0416/h**. 이번 실습에선 몇 분만 떠 있었습니다
- `max_size = 3`이 **비용 상한** 역할도 합니다. 오토스케일링을 켤 땐 max부터 정하세요
- 기본 시간당 합계는 그대로 **≈ $0.24** (노드 2대 기준)

## 다음 (Day 11)

**관측성** — 오늘 metrics-server는 "지금 이 순간" 값만 갖고 있었습니다.
이력과 대시보드(CloudWatch Container Insights), 그리고 Day 2에서 비용 때문에 꺼둔
컨트롤 플레인 로그(`enabled_cluster_log_types`)를 다룹니다.

Karpenter(ASG 없이 노드를 직접 만드는 방식)는 Cluster Autoscaler와 비교하는
심화 주제로 남겨둡니다.
