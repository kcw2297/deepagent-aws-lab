# 입력 변수 정의. 값은 terraform.tfvars 에서 채웁니다.
# 변수로 빼두면 CIDR/리전/이름 같은 걸 코드 수정 없이 바꿀 수 있습니다.

variable "region" {
  description = "리소스를 생성할 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project" {
  description = "리소스 이름/태그의 접두사로 쓰는 프로젝트 이름"
  type        = string
  default     = "deepagent-eks-lab"
}

# ---------- 네트워크 (Day 1) ----------

variable "vpc_cidr" {
  description = "VPC 전체 IP 대역"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "사용할 가용영역(AZ) 목록. 학습용이라 2개면 충분합니다."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "public_subnet_cidrs" {
  description = "퍼블릭 서브넷 CIDR (AZ 순서와 1:1 매칭). 로드밸런서/NAT가 위치."
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20"]
}

variable "private_subnet_cidrs" {
  description = "프라이빗 서브넷 CIDR (AZ 순서와 1:1 매칭). 워커 노드/파드가 위치."
  type        = list(string)
  default     = ["10.0.32.0/20", "10.0.48.0/20"]
}

# ---------- EKS 컨트롤플레인 (Day 2) ----------

variable "kubernetes_version" {
  description = "EKS 클러스터의 쿠버네티스 버전. 지원 목록은 `aws eks describe-cluster-versions`로 확인."
  type        = string
  default     = "1.36"
}

variable "cluster_public_access_cidrs" {
  description = "쿠버네티스 API 서버(퍼블릭 엔드포인트)에 접근 가능한 IP 대역. 조이려면 [\"<내 공인IP>/32\"]."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
