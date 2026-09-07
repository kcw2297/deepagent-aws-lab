# ============================================================================
# Day 2 — EKS 컨트롤플레인
# 쿠버네티스의 "두뇌"(API 서버, 스케줄러, etcd)를 만듭니다.
# AWS가 대신 운영해주는 관리형이라 우리가 서버를 띄우지는 않습니다.
# 대신 두 가지를 준비해야 합니다: ① EKS가 쓸 IAM 역할  ② 어느 서브넷에 놓을지
# ============================================================================

# ----------------------------------------------------------------------------
# 1) 클러스터용 IAM 역할
#
# [왜 필요한가]
# EKS 컨트롤플레인은 우리 계정 안에서 대신 일을 합니다. 예를 들어 노드와
# 통신할 ENI(네트워크 카드)를 서브넷에 만들고, 로드밸런서를 조작합니다.
# 그러려면 "EKS 서비스가 내 계정의 리소스를 건드려도 된다"는 허가가 필요합니다.
#
# [신뢰 정책 vs 권한 정책 — 헷갈리기 쉬운 부분]
#   assume_role_policy (아래)  = "누가 이 역할을 빌릴 수 있는가"  → eks.amazonaws.com
#   policy_attachment (그 아래) = "빌린 뒤 무엇을 할 수 있는가"    → AmazonEKSClusterPolicy
# 둘 다 있어야 동작합니다. 하나만 있으면 권한이 없거나, 아무도 못 빌립니다.
# ----------------------------------------------------------------------------
resource "aws_iam_role" "cluster" {
  name = "${var.project}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com" # EKS 서비스만 이 역할을 빌릴 수 있음
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project}-cluster-role"
  }
}

# AWS가 미리 만들어 둔 관리형 정책을 붙입니다. 직접 정책을 쓰지 않고 이걸 쓰는 게
# EKS의 표준 방식입니다. (AWS가 필요 권한이 바뀌면 알아서 갱신해 줍니다)
resource "aws_iam_role_policy_attachment" "cluster_eks_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ----------------------------------------------------------------------------
# 2) EKS 클러스터 (컨트롤플레인)
#
# 💸 생성되는 순간부터 시간당 $0.10이 과금됩니다. 생성/삭제에 각각 10분 안팎 걸립니다.
# ----------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = "${var.project}-cluster"
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    # [왜 프라이빗 서브넷인가]
    # 여기 적은 서브넷에 EKS가 ENI를 만들어 워커 노드와 통신합니다.
    # 노드가 프라이빗에 있을 예정(Day 3)이므로 컨트롤플레인의 통로도 프라이빗에 둡니다.
    # 최소 2개 AZ가 필요합니다 — Day 1에서 2a/2c에 나눠 만든 이유입니다.
    subnet_ids = aws_subnet.private[*].id

    # [엔드포인트 = 쿠버네티스 API 서버 주소]
    # 위 ENI와는 별개로, AWS가 관리하는 API 서버 접속 주소가 생깁니다.
    #   private = VPC 안에서 접근 (노드가 씀)
    #   public  = 인터넷에서 접근 (내 맥북의 kubectl이 씀)
    # 학습용이라 둘 다 켭니다. public을 끄면 VPC 안에 bastion을 둬야 kubectl이 됩니다.
    endpoint_private_access = true
    endpoint_public_access  = true

    # 퍼블릭 엔드포인트에 접근 가능한 IP 범위.
    # 열려 있어도 IAM 인증을 통과해야 하므로 아무나 들어오지는 못합니다.
    # 더 조이고 싶으면 ["<내 공인IP>/32"]로 바꾸면 되지만, 카페/집을 오가면 매번 수정해야 합니다.
    public_access_cidrs = var.cluster_public_access_cidrs
  }

  access_config {
    # [인증 방식]
    # API      = EKS Access Entries (현재 방식). IAM ↔ K8s 권한 매핑을 AWS API로 관리.
    # CONFIG_MAP = 옛 aws-auth ConfigMap 방식. 실수로 깨뜨리면 클러스터 접근이 막힘.
    # 새로 만들 때는 API를 씁니다. Day 4에서 자세히 다룹니다.
    authentication_mode = "API"

    # 클러스터를 만든 IAM 주체(지금은 IAM 사용자 deepagent)에게 자동으로
    # 관리자 권한을 부여합니다. 이게 false면 만들어 놓고도 kubectl이 안 됩니다.
    bootstrap_cluster_creator_admin_permissions = true
  }

  # [학습 노트] 컨트롤플레인 로그(api, audit 등)를 CloudWatch로 보낼 수 있지만
  # 수집·보관 비용이 별도로 붙어서 지금은 끕니다. Day 11(관측성)에서 다룹니다.
  # enabled_cluster_log_types = ["api", "audit"]

  # 역할에 정책이 붙기 전에 클러스터를 만들면 실패합니다.
  # Terraform은 role_arn 참조로 역할 자체의 순서는 알지만, 정책 부착 순서는 모릅니다.
  depends_on = [aws_iam_role_policy_attachment.cluster_eks_policy]

  tags = {
    Name = "${var.project}-cluster"
  }
}
