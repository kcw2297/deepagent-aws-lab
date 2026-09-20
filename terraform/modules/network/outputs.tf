# network 모듈의 출력.
# cluster 모듈은 여기 없는 값(예: 라우트 테이블 ID)을 볼 수 없습니다 — 그게 경계입니다.

output "vpc_id" {
  description = "생성된 VPC의 ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록 (ALB가 위치)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID 목록 (컨트롤플레인 ENI·워커 노드가 위치)"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_public_ip" {
  description = "NAT 게이트웨이의 공인 IP"
  value       = aws_eip.nat.public_ip
}
