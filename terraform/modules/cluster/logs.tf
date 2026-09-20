# ============================================================================
# 컨트롤 플레인 로그 그룹 (Day 11)
#
# [Day 12에서 여기로 옮긴 이유]
# 원래 eks-observability.tf에 Container Insights 로그 그룹들과 함께 있었지만,
# **클러스터가 이 로그 그룹에 depends_on** 하고 있었습니다.
# 그대로 두면 cluster 모듈 → platform 모듈 → cluster 모듈 순환이 됩니다.
#
#   모듈 경계는 이런 숨은 결합을 드러냅니다.
#   한 파일 안에 있을 땐 보이지 않던 의존 방향이, 모듈로 나누면 컴파일되지 않습니다.
#
# 이 로그 그룹은 이름부터가 /aws/eks/<클러스터>/cluster 이고 클러스터가 켜고 끄는
# 것이므로, 클러스터와 함께 두는 게 맞습니다.
# Container Insights 로그 그룹(에이전트가 쓰는 것)은 platform에 남았습니다.
# ============================================================================

# 이름은 EKS가 정한 규칙 그대로여야 합니다: /aws/eks/<클러스터 이름>/cluster
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project}-eks-cluster-logs"
  }
}
