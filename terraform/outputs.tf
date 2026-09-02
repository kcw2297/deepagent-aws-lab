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
