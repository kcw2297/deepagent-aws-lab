# ============================================================================
# Day 10 — 오토스케일링 (HPA + Cluster Autoscaler)
#
# [확장은 두 층입니다]
#   파드 층 : HPA               — CPU 사용률을 보고 파드 개수를 조절
#   노드 층 : Cluster Autoscaler — Pending 파드를 보고 노드 개수를 조절
#
# 둘은 사슬로 이어집니다:
#   부하 ↑ → HPA가 파드를 늘림 → 노드가 모자라 Pending
#         → Cluster Autoscaler가 ASG desired를 올림 → 노드 추가 → 배치
#
# HPA는 노드를 모르고, Cluster Autoscaler는 CPU를 모릅니다. 각자 자기 층만 봅니다.
#
# [Day 3에서 예고한 것]
# ASG(실행 장치)는 처음부터 있었고 오토스케일러용 태그도 붙어 있었습니다.
#   k8s.io/cluster-autoscaler/enabled                    = true
#   k8s.io/cluster-autoscaler/deepagent-eks-lab-cluster  = owned
# 오늘 그 태그를 보고 찾아올 "두뇌"를 끼웁니다.
#
# [이 파일이 하는 일 / 하지 않는 일]
#   여기(Terraform) : metrics-server 애드온, Cluster Autoscaler의 IAM 권한
#   Helm            : Cluster Autoscaler 자체 (관리형 애드온이 아님 — Day 8 LB Controller와 같음)
#   kubectl         : HPA와 부하 테스트 (k8s/day10/)
#
# 💸 확장되면 노드가 최대 1대 늘어납니다 (max 3). t4g.medium +$0.0416/h
# ============================================================================

# ----------------------------------------------------------------------------
# 1) metrics-server — HPA의 전제 조건
#
# 지금은 `kubectl top nodes` 가 "Metrics API not available"을 냅니다.
# HPA는 파드의 CPU 사용률을 알아야 판단할 수 있는데, 그 숫자를 모아주는 게
# metrics-server입니다. kubelet에서 사용률을 수집해 Metrics API로 제공합니다.
#
# 관리형 애드온이라 Day 6·9와 같은 방식으로 설치합니다.
# (AWS 권한이 필요 없습니다 — 클러스터 안의 kubelet만 조회합니다)
# ----------------------------------------------------------------------------
resource "aws_eks_addon" "metrics_server" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "metrics-server"
  addon_version = var.addon_version_metrics_server

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]

  tags = {
    Name = "${var.project}-metrics-server"
  }
}

# ----------------------------------------------------------------------------
# 2) Cluster Autoscaler용 IAM 역할 — Pod Identity (Day 7·8·9와 같은 패턴)
# ----------------------------------------------------------------------------
resource "aws_iam_role" "cluster_autoscaler" {
  name = "${var.project}-cluster-autoscaler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = {
    Name = "${var.project}-cluster-autoscaler-role"
  }
}

# [권한 설계 — 공식 권장 정책을 그대로 따릅니다]
# 출처: kubernetes/autoscaler cluster-autoscaler/cloudprovider/aws/README.md
#
# 조회(Describe*)는 전체 허용, **확장·축소 두 개는 태그 조건으로 제한**합니다.
# 조건이 없으면 이 파드가 계정의 "아무 ASG"나 늘리고 줄일 수 있게 됩니다.
# 우리 클러스터 소유(owned)로 표시된 ASG만 건드리도록 좁힙니다.
#
# Day 8 LB Controller는 AWS가 준 정책 파일을 그대로 썼고,
# Day 9 EBS CSI는 AWS 관리형 정책(ARN)을 썼습니다.
# Cluster Autoscaler는 관리형 정책이 없어서 직접 작성합니다 — 그래서 조건까지 보입니다.
resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "cluster-autoscaler"
  role = aws_iam_role.cluster_autoscaler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadOnly"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        Sid    = "ScaleOnlyOwnedAsg"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",                  # 확장·축소
          "autoscaling:TerminateInstanceInAutoScalingGroup", # 특정 노드를 골라 제거
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled"                      = "true"
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${aws_eks_cluster.this.name}" = "owned"
          }
        }
      },
    ]
  })
}

# Helm 차트가 kube-system에 만들 SA 이름과 맞춥니다.
# (k8s/day10/cluster-autoscaler-values.yaml 의 rbac.serviceAccount.name)
# SA가 아직 없어도 연결은 만들어집니다 — Day 8에서 확인한 순서입니다.
resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler.arn

  depends_on = [aws_eks_addon.pod_identity]

  tags = {
    Name = "${var.project}-cluster-autoscaler-podid"
  }
}
