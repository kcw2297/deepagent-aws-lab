# ============================================================================
# OIDC 발급자 등록 (Day 7 IRSA의 전제)
#
# [Day 12에서 여기로 옮긴 이유]
# 원래 eks-irsa.tf에 데모 역할들과 함께 있었지만, OIDC 발급자는 **클러스터의
# 신원 그 자체**입니다. 데모 역할은 바꿔 끼울 수 있어도 이건 클러스터와 한 몸입니다.
# 그래서 cluster 모듈에 두고, 쓰는 쪽(platform)에는 output으로 넘깁니다.
# ============================================================================

# OIDC 발급자의 TLS 인증서를 가져옵니다. 지문(thumbprint)이 필요해서입니다.
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# ① IAM에 OIDC 발급자 등록
#    이게 없으면 AWS는 클러스터가 발급한 토큰을 "모르는 출처"로 보고 거부합니다.
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${var.project}-oidc"
  }
}

locals {
  # 조건 키는 "https://"를 뗀 호스트+경로 형태로 써야 합니다.
  oidc_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}
