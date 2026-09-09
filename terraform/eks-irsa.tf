# ============================================================================
# Day 7 — 파드에 AWS 권한 주기 (IRSA · Pod Identity)
#
# [해결하려는 문제]
# 일반 파드는 AWS 자격증명이 아예 없습니다. 직접 확인해보면:
#   kubectl run t --rm -i --image=public.ecr.aws/aws-cli/aws-cli --command -- \
#     aws sts get-caller-identity
#   → NoCredentials: Unable to locate credentials
#
# 왜 없나? 노드의 IMDS(169.254.169.254)에서 역할 자격증명을 가져올 수 있을 것
# 같지만, EKS 관리형 노드 그룹은 IMDS의 HttpPutResponseHopLimit을 1로 둡니다.
# 파드의 네트워크 네임스페이스에서 나가는 패킷은 홉이 하나 더 늘어나 TTL이 소진돼
# 차단됩니다. (hostNetwork 파드는 홉이 안 늘어나므로 접근 가능 —
#  그래서 aws-node가 노드 역할을 쓸 수 있습니다)
#
# 즉 기본 상태는 "모든 파드가 노드 권한을 공유"가 아니라 "파드에 권한이 없음"입니다.
# 그래서 파드별로 권한을 주는 장치가 필요합니다.
#
# 💰 비용 $0 — IAM 리소스와 Pod Identity 애드온 모두 무료입니다.
# ============================================================================

# ----------------------------------------------------------------------------
# 방법 A — IRSA (IAM Roles for Service Accounts)
#
# 원리: 쿠버네티스가 ServiceAccount에게 발급하는 JWT를, AWS가 신뢰하게 만듭니다.
#   Day 5에서 본 그 토큰입니다:
#     발급자(iss): https://oidc.eks.ap-northeast-2.amazonaws.com/id/<클러스터>
#     주체(sub)  : system:serviceaccount:<네임스페이스>:<SA이름>
#
#   ① IAM에 "이 OIDC 발급자를 신뢰한다"고 등록
#   ② 역할의 신뢰 정책에 "그 발급자가 준 토큰 중 sub가 이것인 경우만" 조건을 걸기
#   ③ 파드는 그 토큰으로 sts:AssumeRoleWithWebIdentity 호출 → 임시 자격증명
# ----------------------------------------------------------------------------

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

# ② 그 발급자를 신뢰하는 역할
#
# [Day 2·3의 역할과 비교 — 신뢰하는 대상이 또 다릅니다]
#   클러스터 역할  : Service   = eks.amazonaws.com      (AWS 서비스)
#   노드 역할      : Service   = ec2.amazonaws.com      (AWS 서비스)
#   IRSA 역할(여기): Federated = OIDC provider ARN      (외부 신원 공급자)
#
# Action도 다릅니다. sts:AssumeRole이 아니라 sts:AssumeRoleWithWebIdentity입니다
# — "웹 토큰을 제시하며 역할을 빌린다"는 뜻입니다.
resource "aws_iam_role" "irsa_demo" {
  name = "${var.project}-irsa-demo-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # sub 조건이 핵심입니다. 이게 없으면 이 클러스터의 "아무 SA나"
          # 이 역할을 빌릴 수 있게 됩니다 — 흔한 보안 실수입니다.
          "${local.oidc_host}:sub" = "system:serviceaccount:demo:irsa-demo"
          # aud(audience)도 고정합니다.
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name = "${var.project}-irsa-demo-role"
  }
}

locals {
  # 조건 키는 "https://"를 뗀 호스트+경로 형태로 써야 합니다.
  oidc_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# ③ 권한: 노드 역할이 갖지 "않은" 것을 고릅니다.
#    노드 역할에는 ECR 읽기 권한이 있어서, ECR로 실험하면
#    "IRSA 덕분인지 노드 역할 덕분인지" 구분이 안 됩니다.
#    s3:ListAllMyBuckets는 노드 역할에 없으므로 차이가 분명히 드러납니다.
resource "aws_iam_role_policy" "irsa_demo" {
  name = "list-buckets"
  role = aws_iam_role.irsa_demo.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListAllMyBuckets"]
      Resource = "*"
    }]
  })
}

# ----------------------------------------------------------------------------
# 방법 B — EKS Pod Identity (최신 방식)
#
# IRSA의 불편한 점을 덜어낸 방식입니다.
#   IRSA          : 클러스터마다 OIDC provider 등록 필요.
#                   역할 신뢰 정책에 클러스터별 OIDC URL이 박힘 → 재사용 어려움.
#                   ServiceAccount에 애노테이션 필요.
#   Pod Identity  : OIDC provider 불필요. 신뢰 대상은 pods.eks.amazonaws.com 고정.
#                   → 같은 역할을 여러 클러스터에서 재사용 가능.
#                   애노테이션 대신 "연결(association)" 리소스로 묶음.
#
# 대신 에이전트(DaemonSet)를 깔아야 하고, EKS 전용이라 EKS 밖에서는 못 씁니다.
# ----------------------------------------------------------------------------

# 에이전트를 애드온으로 설치합니다. 파드에 자격증명을 전달하는 역할을 합니다.
resource "aws_eks_addon" "pod_identity" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = var.addon_version_pod_identity

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]

  tags = {
    Name = "${var.project}-pod-identity-agent"
  }
}

# 신뢰 대상이 단순합니다 — OIDC URL도, sub 조건도 없습니다.
# "어느 SA가 이 역할을 쓸지"는 아래 association이 정합니다.
resource "aws_iam_role" "pod_identity_demo" {
  name = "${var.project}-podid-demo-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      # AssumeRole 외에 TagSession이 추가로 필요합니다.
      # Pod Identity가 세션에 네임스페이스/SA 정보를 태그로 심기 때문입니다.
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = {
    Name = "${var.project}-podid-demo-role"
  }
}

resource "aws_iam_role_policy" "pod_identity_demo" {
  name = "list-buckets"
  role = aws_iam_role.pod_identity_demo.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListAllMyBuckets"]
      Resource = "*"
    }]
  })
}

# "demo 네임스페이스의 podid-demo SA는 이 역할을 쓴다"는 연결.
# IRSA에서는 이 정보가 ① 역할의 sub 조건 ② SA 애노테이션 두 곳에 흩어져 있는데,
# Pod Identity에서는 이 리소스 한 곳에 모입니다.
resource "aws_eks_pod_identity_association" "demo" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "demo"
  service_account = "podid-demo"
  role_arn        = aws_iam_role.pod_identity_demo.arn

  depends_on = [aws_eks_addon.pod_identity]

  tags = {
    Name = "${var.project}-podid-demo"
  }
}
