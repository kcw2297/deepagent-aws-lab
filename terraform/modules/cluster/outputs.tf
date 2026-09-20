# cluster 모듈의 출력. platform 모듈과 루트가 쓰는 값들입니다.

output "cluster_name" {
  description = "EKS 클러스터 이름 (aws eks update-kubeconfig --name)"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "쿠버네티스 API 서버 주소"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "실행 중인 쿠버네티스 버전"
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "EKS가 자동 생성한 클러스터 보안그룹 (컨트롤플레인 ↔ 노드)"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group_name" {
  description = "관리형 노드 그룹 이름"
  value       = aws_eks_node_group.this.node_group_name
}

output "node_group_status" {
  description = "노드 그룹 상태. ACTIVE면 조인 완료"
  value       = aws_eks_node_group.this.status
}

output "node_role_arn" {
  description = "워커 노드 IAM 역할"
  value       = aws_iam_role.node.arn
}

output "node_asg_names" {
  description = "EKS가 만든 ASG 이름 (Cluster Autoscaler가 태그로 찾아가는 그것)"
  value       = aws_eks_node_group.this.resources[0].autoscaling_groups[*].name
}

output "viewer_role_arn" {
  description = "읽기 전용 역할 ARN (Day 4 Access Entry 실습용)"
  value       = aws_iam_role.viewer.arn
}

output "oidc_provider_arn" {
  description = "IAM에 등록된 클러스터 OIDC provider (IRSA의 전제)"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_issuer_host" {
  description = "OIDC 발급자 호스트 (https:// 없는 형태). IRSA 신뢰 정책의 조건 키에 씁니다"
  value       = local.oidc_host
}

output "cluster_log_group_name" {
  description = "컨트롤플레인 로그 그룹 (Terraform이 보관 기간을 지정해 관리)"
  value       = aws_cloudwatch_log_group.eks_cluster.name
}
