# ============================================================================
# Day 1 — 네트워크 계층
# EKS는 스스로 네트워크를 만들지 않습니다. 우리가 만든 VPC 안에 클러스터를 얹습니다.
# 여기서는 표준적인 "퍼블릭/프라이빗 서브넷 + NAT" 구조를 손으로 만듭니다.
# ============================================================================

# ----------------------------------------------------------------------------
# 1) VPC — 우리만의 격리된 가상 네트워크 (10.0.0.0/16, 약 65,536개 IP)
# ----------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # EKS/파드 네트워킹, 로드밸런서가 DNS 이름을 쓰려면 둘 다 필요합니다.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-vpc"
  }
}

# ----------------------------------------------------------------------------
# 2) 인터넷 게이트웨이(IGW) — VPC를 인터넷과 연결하는 관문
#    퍼블릭 서브넷의 트래픽이 바깥으로 나가는 문입니다.
# ----------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project}-igw"
  }
}

# ----------------------------------------------------------------------------
# 3) 퍼블릭 서브넷 — AZ마다 하나씩. 외부에서 접근 가능한 자원(로드밸런서, NAT)이 위치.
#    count로 AZ 개수만큼 반복 생성합니다. (var.azs 길이 = 2)
# ----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # 이 서브넷에 뜨는 인스턴스는 퍼블릭 IP를 자동 할당받습니다.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-public-${var.azs[count.index]}"
    # [EKS 태그] 외부 로드밸런서(ALB/NLB)를 이 서브넷에 만들라고 알려주는 표식.
    # Day 8(Load Balancer Controller)에서 실제로 사용됩니다.
    "kubernetes.io/role/elb" = "1"
  }
}

# ----------------------------------------------------------------------------
# 4) 프라이빗 서브넷 — AZ마다 하나씩. 워커 노드와 파드가 실제로 위치하는 곳.
#    외부에서 직접 접근 불가. 나가는 트래픽은 NAT를 거칩니다. (더 안전)
# ----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.project}-private-${var.azs[count.index]}"
    # [EKS 태그] 내부 로드밸런서 배치용 표식.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ----------------------------------------------------------------------------
# 5) NAT 게이트웨이 — 프라이빗 서브넷의 자원이 "바깥으로 나가기만" 하도록 해줍니다.
#    (인터넷에서 안으로 들어오는 연결은 불가). 예: 노드가 컨테이너 이미지를 pull.
#    비용 절약을 위해 학습용은 NAT 1개만 둡니다. (운영은 AZ마다 두는 게 정석)
# ----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-nat-eip"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # NAT는 퍼블릭 서브넷에 위치해야 합니다.

  tags = {
    Name = "${var.project}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}

# ----------------------------------------------------------------------------
# 6) 라우트 테이블 — "이 목적지로 가려면 어느 게이트웨이로 보내라"는 규칙표.
# ----------------------------------------------------------------------------

# 퍼블릭용: 인터넷(0.0.0.0/0)으로 가는 트래픽은 IGW로.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.project}-public-rt"
  }
}

# 프라이빗용: 인터넷으로 가는 트래픽은 NAT로.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.project}-private-rt"
  }
}

# 라우트 테이블을 각 서브넷에 연결(association)해야 실제로 규칙이 적용됩니다.
resource "aws_route_table_association" "public" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
