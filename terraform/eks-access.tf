# ============================================================================
# Day 4 — 접근 제어 (Access Entries)
#
# Day 2~3에서 클러스터와 노드를 만들었지만, 클러스터를 조작할 수 있는 건
# "클러스터를 만든 나" 한 명뿐입니다. bootstrap_cluster_creator_admin_permissions
# 한 줄이 나를 위한 Access Entry를 자동으로 만들어줬기 때문입니다.
#
# 오늘은 "남에게 권한을 주는 법"을 배웁니다.
# 읽기 전용 역할을 만들고, 진짜로 읽기만 되는지 실험합니다.
#
# 💰 비용 $0 — IAM 역할과 Access Entry는 무료입니다.
# ============================================================================

# 현재 terraform을 실행 중인 주체(지금은 IAM 사용자 deepagent)를 알아냅니다.
# 아래 신뢰 정책에서 "누가 이 역할을 빌릴 수 있는지" 지정하는 데 씁니다.
data "aws_caller_identity" "current" {}

# ----------------------------------------------------------------------------
# 1) 읽기 전용 역할 (IAM 계층)
#
# [핵심: 이 역할에는 IAM 정책을 하나도 붙이지 않습니다]
# 이상하게 보이지만 의도된 것입니다. `aws eks get-token`은 AWS API를 호출하지 않고
# 로컬에서 서명만 하므로 아무 권한도 필요 없습니다.
# 즉 IAM 권한이 0인 역할로도 클러스터에 "들어갈" 수 있습니다.
# 무엇을 할 수 있는지는 전적으로 아래 Access Entry가 결정합니다.
#   → "AWS 권한 ≠ 쿠버네티스 권한"을 눈으로 확인하는 장치입니다.
#
# (참고: 이 역할로 `aws eks update-kubeconfig`까지 하려면 eks:DescribeCluster가
#  필요합니다. 실습에서는 기존 kubeconfig를 그대로 쓰므로 필요 없습니다.)
# ----------------------------------------------------------------------------
resource "aws_iam_role" "viewer" {
  name = "${var.project}-viewer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        # 지금 이 사용자만 이 역할을 빌릴 수 있습니다.
        # 계정 전체에 열려면 "arn:aws:iam::<계정ID>:root" 로 바꿉니다.
        AWS = data.aws_caller_identity.current.arn
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project}-viewer-role"
  }
}

# ----------------------------------------------------------------------------
# 2) Access Entry — 번역표에 한 줄 추가 (인증 계층)
#
# "이 IAM 역할 = 쿠버네티스에서는 이런 신원" 이라는 매핑입니다.
# 이것만 있으면 클러스터에 들어올 수는 있지만, 아직 아무것도 못 합니다.
# 쿠버네티스 리소스가 아니라 EKS(AWS)가 들고 있는 데이터라는 점이 중요합니다.
# ----------------------------------------------------------------------------
resource "aws_eks_access_entry" "viewer" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.viewer.arn

  # STANDARD = 사람/역할용 일반 항목.
  # Day 3에서 노드 역할이 EC2_LINUX 타입으로 자동 등록됐던 것과 대비됩니다.
  type = "STANDARD"
}

# ----------------------------------------------------------------------------
# 3) 액세스 정책 연결 — 권한 부여 (인가 계층)
#
# Access Entry가 "너는 누구다"라면, 이건 "너는 뭘 할 수 있다"입니다.
# 둘이 별개라서 리소스도 따로입니다. (aws eks describe-access-entry 와
#  aws eks list-associated-access-policies 가 나뉘어 있는 이유)
#
# AmazonEKSViewPolicy = AWS가 만들어 둔 읽기 전용 RBAC 묶음.
# 직접 ClusterRole/ClusterRoleBinding을 쓰지 않아도 됩니다.
# ----------------------------------------------------------------------------
resource "aws_eks_access_policy_association" "viewer" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.viewer.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    # cluster = 클러스터 전체에서 읽기 가능.
    # namespace 로 바꾸고 namespaces = ["dev"] 를 주면 그 네임스페이스만 볼 수 있습니다.
    type = "cluster"
  }

  # Access Entry가 먼저 존재해야 정책을 연결할 수 있습니다.
  depends_on = [aws_eks_access_entry.viewer]
}
