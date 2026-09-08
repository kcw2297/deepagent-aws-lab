# ============================================================================
# Day 3 — 노드 그룹 (워커 노드)
# Day 2에서 만든 컨트롤플레인은 "명령을 받을 두뇌"였습니다. 일할 근육이 없었죠.
# 오늘 파드가 실제로 돌아갈 EC2를 띄우고 클러스터에 조인시킵니다.
#
# 이번에는 진짜 내 계정의 EC2가 생깁니다. Day 2와의 가장 큰 차이입니다.
# ============================================================================

# ----------------------------------------------------------------------------
# 1) 노드용 IAM 역할
#
# [Day 2의 클러스터 역할과 무엇이 다른가 — 오늘의 핵심 비교]
#
#                    클러스터 역할(Day 2)      노드 역할(오늘)
#   신뢰 서비스       eks.amazonaws.com        ec2.amazonaws.com   ← 여기!
#   누가 빌리나       EKS 서비스                내 EC2 인스턴스
#   무엇을 하나       내 VPC 리소스 조작        클러스터 조인, 이미지 pull
#
# 신뢰 서비스가 ec2인 이유는 간단합니다. 이번엔 진짜 EC2가 이 역할을 쓰기 때문입니다.
# EC2가 역할을 쓰는 방식을 "인스턴스 프로파일"이라고 하는데,
# 관리형 노드 그룹에서는 EKS가 알아서 붙여줍니다.
# ----------------------------------------------------------------------------
resource "aws_iam_role" "node" {
  name = "${var.project}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com" # 내 EC2 인스턴스가 이 역할을 빌림
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project}-node-role"
  }
}

# 노드에는 정책 3개가 필요합니다. 각각 없으면 무엇이 안 되는지 알아두면
# 나중에 노드가 조인 안 될 때 원인을 빨리 찾습니다.

# ① 클러스터에 조인하고 컨트롤플레인과 통신
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# ② 파드에 VPC IP를 할당 (VPC CNI가 ENI를 만들고 IP를 붙이는 데 필요)
#    이게 없으면 노드는 뜨지만 파드가 IP를 못 받아 Pending 상태로 멈춥니다. Day 6 주제.
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# ③ ECR에서 컨테이너 이미지를 pull
#    CoreDNS 같은 필수 애드온 이미지도 ECR에서 받아오므로 없으면 클러스터가 정상 동작하지 않습니다.
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ----------------------------------------------------------------------------
# 2) 관리형 노드 그룹 (Managed Node Group)
#
# [세 가지 방식 비교 — 왜 관리형인가]
#   관리형 노드 그룹  EKS가 EC2 생성·조인·업그레이드를 대신 해줌. 노드는 내 계정에 보임. ← 오늘
#   자체 관리 노드    직접 ASG/AMI/부트스트랩 스크립트를 관리. 자유롭지만 할 일이 많음.
#   Fargate           서버리스. 노드 자체가 없음. 편하지만 비싸고 제약이 많음(DaemonSet 불가 등).
#
# 학습에는 관리형이 적합합니다. "노드가 어떻게 조인되는가"를 보면서도
# AMI 선택·부트스트랩 같은 잡일은 EKS에 맡길 수 있습니다.
#
# 💸 t3.medium 2대 ≈ 시간당 $0.10 안팎이 추가됩니다.
# ----------------------------------------------------------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project}-ng"
  node_role_arn   = aws_iam_role.node.arn

  # 노드는 프라이빗 서브넷에 둡니다. 외부에서 노드로 직접 들어오는 경로가 없어 안전합니다.
  # 이미지 pull 등 나가는 통신은 Day 1에서 만든 NAT를 통합니다.
  subnet_ids = aws_subnet.private[*].id

  # AL2023 = Amazon Linux 2023. EKS 1.33부터 구형 AL2는 지원되지 않습니다.
  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = [var.node_instance_type]
  disk_size      = var.node_disk_size

  # ON_DEMAND vs SPOT: Spot이 70%쯤 싸지만 AWS가 언제든 회수할 수 있습니다.
  # 지금은 "노드가 조인되는 원리"에 집중하려고 예측 가능한 온디맨드를 씁니다.
  # Spot은 이후 심화 주제(비용 최적화)에서 다룹니다.
  capacity_type = "ON_DEMAND"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # 노드 버전을 올릴 때 한 번에 몇 대까지 내려도 되는지.
  # 학습용 2대 규모에서는 1대씩 교체하는 게 안전합니다.
  update_config {
    max_unavailable = 1
  }

  # 역할에 정책이 붙기 전에 노드를 만들면 조인에 실패합니다.
  # Terraform은 node_role_arn 참조로 역할 순서만 알 뿐, 정책 부착 순서는 모릅니다.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  tags = {
    Name = "${var.project}-ng"
  }

  # [학습 노트] desired_size는 나중에 오토스케일러(Day 10)가 바꿀 수 있습니다.
  # 그때 Terraform이 "원래 값으로 되돌리려" 하면 충돌하므로, 그 시점에
  # lifecycle { ignore_changes = [scaling_config[0].desired_size] } 를 넣게 됩니다.
  # 지금은 오토스케일러가 없으니 그대로 둡니다.
}
