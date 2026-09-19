# Day 11 — 관측성 (컨트롤 플레인 로그 + Container Insights)

> 목표: **클러스터에서 일어난 일을 클러스터 밖에 기록으로 남긴다.**
> Day 10에서는 터미널 4개를 띄워 놓고 "지금" 일어나는 일만 봤습니다.
> 오늘은 같은 실습을 다시 돌리고, **끝난 뒤에** CloudWatch에서 무슨 일이 있었는지 재구성합니다.

## 왜 필요한가 — Day 10의 한계

| Day 10에서 쓴 것 | 한계 |
|---|---|
| `kubectl top` (metrics-server) | **최신 값 하나만** 메모리에 있음. "10분 전 CPU는?"에 답하지 못함 |
| `kubectl logs` | 로그가 **노드 디스크**(`/var/log/pods`)에 있음. CA가 노드를 지우면 **함께 사라짐** |
| `kubectl get -w` | 보고 있을 때만 보임. "**누가** replicas를 바꿨나"는 기록이 없음 |

## 오늘의 구조

```
[컨트롤 플레인 — AWS 운영]                         [CloudWatch Logs]
  API 서버 · 스케줄러 · 컨트롤러 ── EKS가 전송 ──►  /aws/eks/<cluster>/cluster
  (우리가 들어가 볼 수 없음)                           api / audit / authenticator /
                                                       controllerManager / scheduler

[각 워커 노드]
  CloudWatch Agent (DaemonSet) ── 메트릭(EMF) ──►  /aws/containerinsights/<cluster>/performance
                                                       └─► CloudWatch Metrics (ContainerInsights 네임스페이스)
  Fluent Bit      (DaemonSet) ── 파드 로그 ────►  .../application
                               ── kubelet 등 ──►  .../dataplane
                               ── OS 로그 ─────►  .../host
        ↑ 둘 다 hostNetwork (파드 IP = 노드 IP)
        ↑ Pod Identity로 CloudWatch 쓰기 권한 (SA: cloudwatch-agent)
```

## 핵심 개념

### 1. 로그 그룹은 우리가 **먼저** 만든다

로그를 켜기만 하면 EKS와 에이전트가 로그 그룹을 알아서 만듭니다. 그런데 그렇게 만들어진 그룹은:

- 보관 기간 = **무기한**
- **Terraform state 밖** → `destroy` 후에도 남아서 보관 비용이 계속 붙음

Day 8 ALB, Day 9 EBS와 같은 **"state 밖 고아"** 유형입니다. 이름 규칙이 정해져 있으니
**같은 이름으로 먼저 만들어두면** AWS는 그걸 그대로 씁니다.

```hcl
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.project}-cluster/cluster"  # EKS 규칙 그대로
  retention_in_days = var.log_retention_days                     # 1일
}
```

| | 순서 보장 방법 |
|---|---|
| 컨트롤 플레인 로그 | `aws_eks_cluster.this`에 `depends_on = [aws_cloudwatch_log_group.eks_cluster]` |
| Container Insights | 애드온에 `depends_on = [aws_cloudwatch_log_group.container_insights]` |

destroy는 역순이라 **에이전트가 먼저 사라진 뒤** 로그 그룹이 지워집니다.
반대면 살아 있는 에이전트가 지운 그룹을 다시 만들 수 있습니다.

로그 그룹 이름에 `aws_eks_cluster.this.name`을 쓰지 않은 이유: 클러스터가 로그 그룹에
`depends_on`하므로 참조하면 **순환**이 생깁니다. 같은 식(`var.project`)으로 직접 만듭니다.

적용 후 확인 — 5개 모두 보관 1일, 그 외 그룹 없음:

```
/aws/containerinsights/deepagent-eks-lab-cluster/application   1
/aws/containerinsights/deepagent-eks-lab-cluster/dataplane     1
/aws/containerinsights/deepagent-eks-lab-cluster/host          1
/aws/containerinsights/deepagent-eks-lab-cluster/performance   1
/aws/eks/deepagent-eks-lab-cluster/cluster                     1
```

### 2. 컨트롤 플레인 로그 5종

| 종류 | 답해주는 질문 | 오늘 쓴 것 |
|---|---|---|
| `audit` | **누가** 언제 무엇을 바꿨나 | ✅ HPA·CA·node-controller 추적 |
| `authenticator` | IAM 주체 → k8s 사용자 매핑 (Day 4) | |
| `api` | API 서버 동작 | |
| `controllerManager` | 컨트롤러들 (HPA도 여기 안) | |
| `scheduler` | 스케줄러 | |

학습용이라 5종을 다 켰습니다. 운영에서는 `audit`·`authenticator`만 켜는 경우가 많습니다 (양 = 비용).

### 3. 메트릭도 사실은 **로그로** 들어간다

Container Insights 메트릭의 원본은 `performance` 로그 그룹에 **EMF(Embedded Metric Format) 로그**로 들어가고,
CloudWatch가 거기서 숫자를 뽑아 `ContainerInsights` 네임스페이스의 메트릭으로 만듭니다.
그래서 performance 그룹에도 보관 기간을 지정해야 합니다.

### 4. 애드온 기본값은 생각보다 많이 설치한다

`aws eks describe-addon-configuration`으로 스키마를 확인한 결과:

| 구성 요소 | 기본값 | 오늘 | 이유 |
|---|---|---|---|
| containerInsights | 켜짐 | 켜짐 | 오늘의 목적 |
| containerLogs (Fluent Bit) | 켜짐 | 켜짐 | 오늘의 목적 |
| **applicationSignals** | 켜짐 | **끔** | 서비스에 연결된 워크로드에 계측 에이전트를 **자동 주입**. 앱이 모르는 사이 바뀜 |
| **kubeStateMetrics** | 켜짐 | **끔** | OTel 방식용. requests 256m |
| **nodeExporter** | 켜짐 | **끔** | OTel 방식용. DaemonSet이라 **노드마다** requests 256m |

`agent.config`를 주면 기본 에이전트 설정을 **통째로 대체**합니다. 기본 설정에 application_signals
수집이 들어 있어서, 빼려면 직접 써야 했습니다 (`enhanced_container_insights = true`,
`accelerated_compute_metrics = false`).

### 5. 관측 도구도 **requests를 먹는다** — 실습에서 확인

cloudwatch-agent는 노드마다 CPU requests 250m를 잡습니다. 같은 stress를 돌렸더니:

```
Day 10 :  기존 노드마다 stress 3개
Day 11 :  기존 노드마다 stress 2개   ← 5번째부터 Pending
```

실제 사용량이 아니라 **requests로 자리가 줄어든** 것입니다 (Day 10 핵심 개념 3).
nodeExporter까지 켰다면 노드마다 256m가 더 줄었을 겁니다.

### 6. 에이전트는 hostNetwork로 뜬다

```
cloudwatch-agent-5s8zg   IP 10.0.56.14   NODE ip-10-0-56-14   ← 파드 IP = 노드 IP
fluent-bit-rhz2t         IP 10.0.44.58   NODE ip-10-0-44-58
controller-manager       IP 10.0.34.49   NODE ip-10-0-44-58   ← 일반 파드 IP
```

노드 수준 정보(kubelet 메트릭, 호스트 네트워크)를 직접 수집하려고 노드의 네트워크를 그대로 씁니다.
Day 6의 `aws-node`, `kube-proxy`와 같은 부류이고, VPC CNI에서 IP를 따로 받지 않습니다.

### 7. data 소스가 만드는 "가짜 변경"

`make plan`에서 의도하지 않은 변경이 하나 보였습니다:

```
~ aws_iam_openid_connect_provider.eks
    ~ thumbprint_list = ["06b25927..."] -> (known after apply)
```

Day 7의 `data "tls_certificate"`가 `aws_eks_cluster.this`를 참조하는데, 클러스터에
(로그 설정) 변경이 예정돼 있으니 Terraform이 data 읽기를 **apply 시점으로 미룬** 것입니다.
실제 값은 같았고, apply 후 `make plan`은 `No changes`였습니다.

> data 소스가 변경 예정 리소스를 참조하면 이런 표시가 생깁니다.
> `known after apply`의 **원인이 어느 리소스의 변경인지** 따라가 보면 됩니다.

### 8. 실무에서는 CloudWatch와 Prometheus를 함께 쓴다

| 대상 | 주로 쓰는 것 | 이유 |
|---|---|---|
| AWS 관리형 서비스 (ALB, RDS, NAT…) | CloudWatch | 이 메트릭은 **CloudWatch에만** 있음 |
| EKS 컨트롤 플레인 로그 | CloudWatch Logs | 보낼 수 있는 곳이 여기뿐 |
| 클러스터 안 (파드·노드·앱) | Prometheus | 생태계 표준, 대부분의 차트가 `/metrics` 제공, 카디널리티 비용 |
| 대시보드 | Grafana | Prometheus + CloudWatch를 **둘 다** 데이터 소스로 |

오늘은 k8s 학습을 우선해 **Container Insights**(A 방식)를 택했습니다.
어떤 조합이든 **컨트롤 플레인 로그는 CloudWatch가 필수**입니다. Prometheus/Grafana는 심화 주제로 남깁니다.

## 오늘 만든 것

| 위치 | 내용 |
|---|---|
| `terraform/eks-observability.tf` | 로그 그룹 5개(보관 1일), CloudWatch Agent IAM 역할 + `CloudWatchAgentServerPolicy`, `amazon-cloudwatch-observability` 애드온 (Pod Identity 내장) |
| `terraform/eks-cluster.tf` | `enabled_cluster_log_types = var.cluster_log_types`, 로그 그룹 `depends_on` |
| `terraform/variables.tf` · `terraform.tfvars` | `cluster_log_types`, `log_retention_days = 1`, `addon_version_cloudwatch_observability = "v6.6.0-eksbuild.1"` |
| `terraform/outputs.tf` | `cloudwatch_agent_role_arn`, `log_group_names` |
| `k8s/day10/stress.yaml` | 시작 시 `stress <파드> started on <노드>` 출력 (Downward API `spec.nodeName`) |

## 실습 순서

```bash
# 1) 적용 — 클러스터는 in-place 변경이어야 함 (-/+ 이면 중단)
make plan && make apply
kubectl get pods -n amazon-cloudwatch -o wide
aws logs describe-log-groups --region ap-northeast-2 --log-group-name-prefix /aws \
  --query "logGroups[].[logGroupName,retentionInDays]" --output table

# 2) Day 10 부하 재실행 — 이번엔 지켜보지 않고 나중에 기록으로 확인
kubectl apply -f k8s/day10/stress.yaml
kubectl delete -f k8s/day10/stress.yaml    # 노드가 늘고 줄어든 뒤

# 3) 기록으로 재구성 (아래 쿼리)
export AWS_PAGER=""   # CLI가 결과를 less로 여는 것 방지
```

### Logs Insights를 CLI로 실행하기

콘솔 메뉴가 **Logs → Log Analytics**로 바뀌어 있었습니다 (예전 Logs Insights).
메뉴와 상관없이 CLI로 같은 쿼리를 돌릴 수 있습니다:

```bash
QID=$(aws logs start-query --region ap-northeast-2 \
  --log-group-name <로그 그룹> \
  --start-time $(date -v-1H +%s) --end-time $(date +%s) \
  --query-string '<쿼리>' \
  --query queryId --output text)
sleep 5
aws logs get-query-results --region ap-northeast-2 --query-id $QID \
  --query 'results[*][*].value' --output text
```

`start-query`는 **시작만** 하고 ID를 돌려줍니다(비동기). 결과가 비면 `get-query-results`를 다시 실행합니다.

| 목적 | 로그 그룹 | 쿼리 |
|---|---|---|
| 사라진 노드의 로그 | `.../application` | `filter kubernetes.host like /ip-10-0-55-147/ \| stats count() by kubernetes.namespace_name, kubernetes.pod_name` |
| HPA가 바꾼 replicas | `/aws/eks/.../cluster` | `filter @logStream like /kube-apiserver-audit/ and objectRef.namespace = "scale-demo" and objectRef.subresource = "scale" and verb in ["update","patch"] \| fields @timestamp, user.username, verb, requestObject.spec.replicas \| sort @timestamp asc` |
| CA가 노드에 한 일 | `/aws/eks/.../cluster` | `filter @logStream like /kube-apiserver-audit/ and user.username = "system:serviceaccount:kube-system:cluster-autoscaler" and objectRef.resource = "nodes" and verb not in ["get","list","watch"] \| fields @timestamp, verb, objectRef.name` |
| 누가 Node를 지웠나 | `/aws/eks/.../cluster` | `filter @logStream like /kube-apiserver-audit/ and objectRef.resource = "nodes" and verb = "delete" \| fields @timestamp, user.username, objectRef.name` |

노드 수 이력 (메트릭):

```bash
aws cloudwatch get-metric-statistics --region ap-northeast-2 \
  --namespace ContainerInsights --metric-name cluster_node_count \
  --dimensions Name=ClusterName,Value=deepagent-eks-lab-cluster \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Maximum \
  --query "sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]" --output table
```

## 실습 결과

실습 중 부하를 **너무 일찍 지워서** 의도와 다르게 흘러갔지만, 오히려 더 많은 것이 드러났습니다.

```
1차 : Pending 1초 만에 삭제 → 그래도 CA는 이미 확장 요청 → ip-10-0-55-147 부팅
2차 : 4개까지만 늘고 삭제 → 전부 기존 노드에. 55-147은 빈 채로 떠 있다가 축소
```

**CA는 한번 결정한 확장을 취소하지 않습니다.** 원인 파드가 사라져도 노드는 뜨고,
정리는 축소 로직이 따로 합니다.

### ① 사라진 노드의 로그가 남았다

```
kube-system        eks-pod-identity-agent-l5wbt    13
amazon-cloudwatch  fluent-bit-5w9v9                 6
amazon-cloudwatch  cloudwatch-agent-x2qws         897
kube-system        ebs-csi-node-qm2vg              29
```

`kubectl logs`로는 `NotFound`인 파드들의 로그가 CloudWatch에는 남아 있습니다.
**노드 수명이 짧은 오토스케일링 환경에서 로그 수집이 필수인 이유**입니다.

- `aws-node`, `kube-proxy`는 `application`이 아니라 **`dataplane`** 그룹으로 갑니다
- 3분 남짓 떠 있던 노드에서 **cloudwatch-agent 자신이 897줄**로 가장 많이 남겼습니다 — 수집기의 로그량도 비용입니다

### ② HPA 기록 — 누가, 몇으로

| @timestamp (UTC) | 신원 | replicas | 어느 실행 |
|---|---|---|---|
| 10:16:49.742 ~ .883 | `system:serviceaccount:kube-system:horizontal-pod-autoscaler` | 2 → 4 → 8 → 10 | Day 10 (아래 참고) |
| 10:23:21 / :51 / 10:24:21 | 〃 | 2 → 4 → **6** | 1차 |
| 10:25:35 / 10:26:20 | 〃 | 2 → 4 | 2차 |

- HPA는 파드가 아니라 **kube-controller-manager 안의 컨트롤러**이고, **전용 ServiceAccount**로 API를 호출합니다
- 간격 **30초** = 메트릭 수집(15s) + HPA 계산(15s)
- 4 → 6: 방금 뜬 파드는 메트릭이 없어서, 확장 판단 때 **사용률 0%로 보고** 보수적으로 계산한 것으로 보입니다

### ③ CA 기록 — taint 두 번, 정확히 1분 간격

```
10:25:26  update  ip-10-0-55-147   DeletionCandidateOfClusterAutoscaler (PreferNoSchedule)
             ↓ 1분 = scale-down-unneeded-time
10:26:26  update  ip-10-0-55-147   ToBeDeletedByClusterAutoscaler (NoSchedule) → drain → 인스턴스 종료
```

values 파일에 적은 **1분**이 audit에 실제 간격으로 찍혔습니다.

### ④ Node 객체를 지운 건 CA가 아니다

```
10:27:58  system:serviceaccount:kube-system:node-controller   delete  ip-10-0-55-147
```

| 주체 | 하는 일 |
|---|---|
| Cluster Autoscaler | 지울지 **결정**, taint·drain, **AWS API로 인스턴스 종료** |
| ASG / EC2 | 인스턴스 실제 종료 |
| **node-controller** | "인스턴스가 클라우드에서 사라졌다"를 감지해 **Node 객체 삭제** |

그래서 CA로 줄이든, 콘솔에서 EC2를 종료하든, 스팟이 회수되든 Node 객체는 같은 방식으로 정리됩니다.
**각 컨트롤러는 자기 일 하나만 하고, 서로를 직접 부르지 않고, API 서버의 상태를 보고 반응합니다** —
HPA와 CA가 Pending 파드로만 이어졌던 것과 같은 구조입니다.

### ⑤ 노드 수 이력

```
19:17 ~ 19:23 KST   2
19:24 ~ 19:26 KST   3     ← 1차 실행이 부른 55-147
19:27 ~             2
```

- 메트릭은 **KST**, audit `@timestamp`는 **UTC**로 나왔습니다 (19:24 KST = 10:24 UTC)
- 데이터는 **19:17부터** — 에이전트 설치 이후만 있고 과거는 채워지지 않습니다

### ⚠️ `@timestamp`는 "일어난 시각"이 아닐 수 있다 (추정)

②의 첫 묶음은 1→10 확장 4번이 **0.15초 안에** 찍혔고, ③·④에서 같은 시각대(10:16:50~55)에
**Day 10 실행 때 지워진 노드** `ip-10-0-59-42`의 기록이 함께 나왔습니다. 실제로는 2분 넘게 걸린 일입니다.

로그를 켠 순간 **이전 audit 이벤트가 한꺼번에 전달되어** `@timestamp`가 전달 시각으로 찍힌 것으로 추정합니다.
audit 이벤트 안의 `requestReceivedTimestamp`와 비교하면 확인할 수 있습니다 (미확인).

> 시간 순서가 중요한 조사라면 CloudWatch의 `@timestamp`가 아니라
> **이벤트 자체의 시각 필드**(`requestReceivedTimestamp`, `stageTimestamp`)를 기준으로 삼으세요.

## 정리 — `make destroy`

변경 없음. 로그 그룹 5개가 모두 **Terraform 관리**라 destroy에 함께 지워집니다.
이것이 오늘 로그 그룹을 먼저 만든 이유입니다.

## 관찰 포인트

1. 로그 그룹을 Terraform으로 먼저 만들지 않았다면 destroy 후 무엇이 남나?
2. Container Insights 메트릭은 왜 **로그 그룹**에 보관 기간을 줘야 하나?
3. cloudwatch-agent를 설치했더니 stress가 노드당 3개 → 2개로 준 이유는?
4. HPA와 CA가 audit에 어떤 신원으로 찍혔나? 둘 중 AWS API도 호출하는 쪽은?
5. CA가 노드에 update를 두 번 한 이유와 그 간격은?
6. Node 객체를 지운 주체는? CA가 직접 지우지 않는 설계의 장점은?
7. `@timestamp`만 믿고 시간순 분석을 하면 어떤 착오가 생길 수 있나?

## 비용 메모

| 항목 | 단가 (서울, Pricing API 확인) | 오늘 규모 |
|---|---|---|
| 로그 수집 (Standard) | **$0.76/GB** | 수십~수백 MB → 수십 센트 이하 |
| Container Insights (enhanced) | **관측 100만 건당 $0.21** | 노드 2~3대 × 몇 시간 → 센트 단위 |
| 로그 보관 | GB-월 | 1일 보관이라 무시 가능 |

- 처음으로 **시간이 아니라 양으로** 과금되는 리소스입니다. 로그를 많이 찍는 워크로드가 곧 비용입니다
- 시간당 기본 비용은 그대로 **≈ $0.24** + 위 사용량

## 다음 (Day 12)

**리팩터링 — 모듈화 & 환경 분리.** Day 1부터 쌓은 `.tf` 파일을 모듈로 정리합니다.
Day 7~11에서 반복된 **Pod Identity 역할 패턴**(신뢰 정책 + 권한 + 연결)이 모듈화의 첫 후보입니다.
