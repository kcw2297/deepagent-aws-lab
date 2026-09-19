# ============================================================================
# Day 11 — 관측성 (컨트롤 플레인 로그 + Container Insights)
#
# [Day 10에서 본 한계]
#   kubectl top  (metrics-server) → "지금 이 순간" 값만. 10분 전은 모릅니다
#   kubectl logs                  → 노드 디스크(/var/log/pods)에 있어서
#                                   CA가 노드를 지우면 그 노드의 로그도 사라집니다
#   kubectl get -w                → 내가 보고 있을 때만. "누가 바꿨나"는 기록이 없습니다
#
# 오늘은 이것들을 클러스터 밖(CloudWatch)에 남깁니다.
#
#   ① 컨트롤 플레인 로그 → /aws/eks/<cluster>/cluster
#      AWS가 운영하는 영역이라 우리가 들어가 볼 방법이 이것뿐입니다.
#   ② Container Insights → /aws/containerinsights/<cluster>/{performance,application,...}
#      노드마다 CloudWatch Agent(메트릭) + Fluent Bit(로그) DaemonSet이 뜹니다.
#
# [핵심: 로그 그룹을 "먼저" 우리가 만든다]
# 로그를 켜기만 하면 EKS와 에이전트가 로그 그룹을 알아서 만듭니다. 그런데 그건
#   - 보관 기간 = 무기한 (Never expire)
#   - Terraform state 밖 → destroy 후에도 남아서 계속 보관 비용
# Day 8 ALB, Day 9 EBS와 같은 "state 밖 고아" 유형입니다.
# 이름이 정해져 있으니 우리가 같은 이름으로 먼저 만들어 두면, AWS는 그걸 그대로 씁니다.
# 그러면 보관 기간도 정할 수 있고 destroy 때 함께 지워집니다.
#
# 💸 처음으로 "시간"이 아니라 "양"으로 과금되는 리소스입니다.
#   로그 수집 : GB당 $0.76 (서울, Standard 클래스). 몇 시간 실습이면 수십~수백 MB
#   Container Insights (enhanced) : 관측(observation) 100만 건당 $0.21 (서울)
#   (aws pricing get-products 로 확인한 값)
#   보관 1일로 두어 쌓이지 않게 합니다.
# ============================================================================

# ----------------------------------------------------------------------------
# 1) 컨트롤 플레인 로그 그룹
#
# 이름은 EKS가 정한 규칙 그대로여야 합니다: /aws/eks/<클러스터 이름>/cluster
# aws_eks_cluster.this.name을 참조하면 "클러스터 → 로그 그룹 → 클러스터" 순환이
# 생기므로, 클러스터 이름과 같은 식(var.project)으로 직접 만듭니다.
# 클러스터 쪽에서 depends_on으로 이 로그 그룹을 먼저 만들게 합니다 (eks-cluster.tf).
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.project}-cluster/cluster"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project}-eks-cluster-logs"
  }
}

# ----------------------------------------------------------------------------
# 2) Container Insights 로그 그룹 4개
#
#   performance : CloudWatch Agent가 보내는 메트릭 원본 (EMF 형식 로그)
#                 → CloudWatch가 여기서 숫자를 뽑아 메트릭으로 만듭니다.
#                   "메트릭도 사실은 로그로 들어간다"는 게 Container Insights의 구조입니다.
#   application : 파드 stdout/stderr (Fluent Bit이 /var/log/containers 를 읽어 보냄)
#                 → 노드가 사라져도 남는 kubectl logs
#   dataplane   : kubelet, containerd, kube-proxy, aws-node 로그
#   host        : 노드 OS 로그 (/var/log/messages, dmesg, secure)
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = toset(["performance", "application", "dataplane", "host"])

  name              = "/aws/containerinsights/${var.project}-cluster/${each.key}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project}-ci-${each.key}"
  }
}

# ----------------------------------------------------------------------------
# 3) CloudWatch Agent / Fluent Bit용 IAM 역할 — Pod Identity (Day 7·8·9·10과 같은 패턴)
#
# 에이전트가 CloudWatch에 메트릭·로그를 "쓰려면" AWS 권한이 필요합니다.
# metrics-server(Day 10)는 클러스터 안에서만 돌아서 권한이 필요 없었던 것과 대비됩니다.
# ----------------------------------------------------------------------------
resource "aws_iam_role" "cloudwatch_agent" {
  name = "${var.project}-cloudwatch-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = {
    Name = "${var.project}-cloudwatch-agent-role"
  }
}

# AWS 관리형 정책 (Day 9 EBS CSI처럼 ARN만 붙입니다).
# cloudwatch:PutMetricData, logs:PutLogEvents/CreateLogStream, ec2:DescribeTags 등.
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ----------------------------------------------------------------------------
# 4) amazon-cloudwatch-observability — 관리형 애드온
#
# [기본값으로 설치하면 생각보다 많은 게 딸려옵니다]
# 애드온 설정 스키마(aws eks describe-addon-configuration)를 확인한 결과:
#
#   containerInsights   : 켜짐  ← 오늘의 목적
#   containerLogs       : 켜짐  ← Fluent Bit. 오늘의 목적
#   applicationSignals  : 켜짐  ← APM. 서비스에 연결된 워크로드에 계측 에이전트를
#                                 "자동 주입"합니다. 우리 앱이 모르는 사이 바뀌므로 끕니다
#   kubeStateMetrics    : 켜짐  ← OTel 기반 Container Insights용. requests 256m
#   nodeExporter        : 켜짐  ← 같은 용도. DaemonSet이라 노드마다 requests 256m
#
# t4g.medium 2대(allocatable 약 1930m)에서 노드마다 256m씩 더 잡히면
# Day 10에서 본 것처럼 자리가 모자라 CA가 노드를 늘릴 수 있습니다. 쓰지 않는 건 끕니다.
#
# Pod Identity 연결은 Day 9처럼 애드온 안에서 바로 합니다.
# SA "cloudwatch-agent"는 CloudWatch Agent와 Fluent Bit이 함께 씁니다.
# ----------------------------------------------------------------------------
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "amazon-cloudwatch-observability"
  addon_version = var.addon_version_cloudwatch_observability

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    containerLogs      = { enabled = true }
    applicationSignals = { enabled = false }
    kubeStateMetrics   = { enabled = false }
    nodeExporter       = { enabled = false }

    # [에이전트 설정 — 이걸 주면 기본 설정을 "통째로 대체"합니다]
    # 기본 설정에는 application_signals 수집도 들어 있어서, 빼려면 직접 써야 합니다.
    #   enhanced_container_insights = true
    #     → 파드·컨테이너 단위까지 세밀한 메트릭. 과금이 "메트릭 개수"가 아니라
    #       "관측 건수" 기준이라 오히려 표준 방식보다 저렴한 편입니다 (AWS 요금 예시 기준)
    #   accelerated_compute_metrics = false
    #     → GPU/Neuron/EFA 메트릭. 우리 노드엔 없습니다
    agent = {
      config = {
        logs = {
          metrics_collected = {
            kubernetes = {
              enhanced_container_insights = true
              accelerated_compute_metrics = false
            }
          }
        }
      }
    }
  })

  pod_identity_association {
    role_arn        = aws_iam_role.cloudwatch_agent.arn
    service_account = "cloudwatch-agent" # 애드온이 amazon-cloudwatch 네임스페이스에 만드는 SA
  }

  # 로그 그룹이 먼저 있어야 에이전트가 "무기한 보관" 그룹을 새로 만들지 않습니다.
  # destroy 때는 역순이라 애드온(에이전트)이 먼저 사라진 뒤 로그 그룹이 지워집니다
  # — 에이전트가 살아 있으면 지운 그룹을 다시 만들어버릴 수 있습니다.
  depends_on = [
    aws_eks_node_group.this,
    aws_eks_addon.pod_identity,
    aws_iam_role_policy_attachment.cloudwatch_agent,
    aws_cloudwatch_log_group.container_insights,
  ]

  tags = {
    Name = "${var.project}-cloudwatch-observability"
  }
}
