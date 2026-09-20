# cluster 모듈의 입력.

variable "project" {
  description = "리소스 이름/태그 접두사"
  type        = string
}

variable "cluster_name" {
  description = "EKS 클러스터 이름. network 모듈의 서브넷 태그와 같은 값이어야 합니다"
  type        = string
}

variable "private_subnet_ids" {
  description = "컨트롤플레인 ENI와 워커 노드를 둘 프라이빗 서브넷 (network 모듈의 출력)"
  type        = list(string)
}

variable "kubernetes_version" {
  description = "쿠버네티스 버전"
  type        = string
}

variable "cluster_public_access_cidrs" {
  description = "API 서버 퍼블릭 엔드포인트에 접근 가능한 IP 대역"
  type        = list(string)
}

# ---------- 노드 그룹 ----------

variable "node_instance_type" {
  description = "워커 노드 인스턴스 타입"
  type        = string
}

variable "node_ami_type" {
  description = "노드 AMI 타입. instance_type의 아키텍처와 일치해야 합니다"
  type        = string
}

variable "node_desired_size" {
  description = "평상시 노드 수 (이후 Cluster Autoscaler가 바꾸며, Terraform은 무시합니다)"
  type        = number
}

variable "node_min_size" {
  description = "노드 최소 수"
  type        = number
}

variable "node_max_size" {
  description = "노드 최대 수 = 비용 상한"
  type        = number
}

variable "node_disk_size" {
  description = "노드 루트 EBS 볼륨 크기(GB)"
  type        = number
}

# ---------- 로그 ----------

variable "cluster_log_types" {
  description = "CloudWatch로 보낼 컨트롤플레인 로그 종류. 빈 목록이면 끕니다"
  type        = list(string)
}

variable "log_retention_days" {
  description = "컨트롤플레인 로그 그룹 보관 기간(일)"
  type        = number
}
