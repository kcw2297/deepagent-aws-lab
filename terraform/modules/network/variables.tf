# network 모듈의 입력.
# 루트에서 넘겨주지 않으면 이 모듈은 아무것도 모릅니다.

variable "project" {
  description = "리소스 이름/태그 접두사"
  type        = string
}

variable "cluster_name" {
  description = <<-EOT
    서브넷 태그(kubernetes.io/cluster/<이름>)에 쓸 EKS 클러스터 이름.

    [왜 클러스터 모듈에서 받지 않고 루트에서 받나]
    network → cluster 순서로 만들어지는데, 클러스터 이름을 클러스터 모듈의 output에서
    받으면 cluster → network 의존이 생겨 **순환**이 됩니다.
    그래서 이름만 루트에서 미리 정해(locals) 양쪽에 똑같이 넘깁니다.
  EOT
  type        = string
}

variable "vpc_cidr" {
  description = "VPC 전체 IP 대역"
  type        = string
}

variable "azs" {
  description = "사용할 가용영역 목록"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "퍼블릭 서브넷 CIDR (AZ 순서와 1:1)"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "프라이빗 서브넷 CIDR (AZ 순서와 1:1)"
  type        = list(string)
}
