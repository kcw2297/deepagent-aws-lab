# 출력값: apply 후 화면에 표시되고, 다음 계층(EKS)에서 참조하기 좋은 값들입니다.

output "vpc_id" {
  description = "생성된 VPC의 ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID 목록 (Day 2에서 EKS/노드가 사용)"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_public_ip" {
  description = "NAT 게이트웨이의 공인 IP (프라이빗 자원이 바깥에 보일 때의 IP)"
  value       = aws_eip.nat.public_ip
}

# ---------- EKS 컨트롤플레인 (Day 2) ----------

output "cluster_name" {
  description = "EKS 클러스터 이름 (Day 4에서 `aws eks update-kubeconfig --name`에 사용)"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "쿠버네티스 API 서버 주소. kubectl이 실제로 접속하는 곳."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "실행 중인 쿠버네티스 버전"
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "EKS가 자동 생성한 클러스터 보안그룹. 컨트롤플레인 ↔ 노드 통신에 사용 (Day 3에서 등장)"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
