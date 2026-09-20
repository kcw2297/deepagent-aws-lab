# 루트의 출력.
# 모듈 안의 리소스를 직접 가리킬 수 없으므로, 모듈의 output을 다시 내보냅니다.
# 이 "한 번 더 쓰는 번거로움"이 모듈 경계의 비용이고, 대신 모듈 내부를 바꿔도
# 밖이 안 깨지는 것이 이득입니다.

# ---------- 네트워크 (Day 1) ----------

output "vpc_id" {
  description = "생성된 VPC의 ID"
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록"
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID 목록"
  value       = module.network.private_subnet_ids
}

output "nat_gateway_public_ip" {
  description = "NAT 게이트웨이의 공인 IP"
  value       = module.network.nat_gateway_public_ip
}

# ---------- 클러스터 (Day 2~4) ----------

output "cluster_name" {
  description = "EKS 클러스터 이름 (Makefile의 kubeconfig 갱신에 사용)"
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "쿠버네티스 API 서버 주소"
  value       = module.cluster.cluster_endpoint
}

output "cluster_version" {
  description = "실행 중인 쿠버네티스 버전"
  value       = module.cluster.cluster_version
}

output "cluster_security_group_id" {
  description = "EKS가 자동 생성한 클러스터 보안그룹"
  value       = module.cluster.cluster_security_group_id
}

output "node_group_name" {
  description = "관리형 노드 그룹 이름"
  value       = module.cluster.node_group_name
}

output "node_group_status" {
  description = "노드 그룹 상태"
  value       = module.cluster.node_group_status
}

output "node_role_arn" {
  description = "워커 노드 IAM 역할"
  value       = module.cluster.node_role_arn
}

output "node_asg_names" {
  description = "EKS가 만든 ASG 이름 (Cluster Autoscaler가 태그로 찾는 그것)"
  value       = module.cluster.node_asg_names
}

output "viewer_role_arn" {
  description = "읽기 전용 역할 ARN (Day 4 실습)"
  value       = module.cluster.viewer_role_arn
}

output "oidc_provider_arn" {
  description = "IAM에 등록된 클러스터 OIDC provider"
  value       = module.cluster.oidc_provider_arn
}

# ---------- 플랫폼 (Day 6~11) ----------

output "addon_versions" {
  description = "Terraform이 관리하는 애드온 버전"
  value       = module.platform.addon_versions
}

output "irsa_demo_role_arn" {
  description = "IRSA 실습용 역할 (Day 7)"
  value       = module.platform.irsa_demo_role_arn
}

output "pod_identity_demo_role_arn" {
  description = "Pod Identity 실습용 역할 (Day 7)"
  value       = module.platform.pod_identity_demo_role_arn
}

output "alb_controller_role_arn" {
  description = "LB Controller 역할 (Day 8)"
  value       = module.platform.alb_controller_role_arn
}

output "ebs_csi_role_arn" {
  description = "EBS CSI 역할 (Day 9)"
  value       = module.platform.ebs_csi_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "Cluster Autoscaler 역할 (Day 10)"
  value       = module.platform.cluster_autoscaler_role_arn
}

output "cloudwatch_agent_role_arn" {
  description = "CloudWatch Agent 역할 (Day 11)"
  value       = module.platform.cloudwatch_agent_role_arn
}

output "log_group_names" {
  description = "Terraform이 관리하는 CloudWatch 로그 그룹 전체"
  value = concat(
    [module.cluster.cluster_log_group_name],
    module.platform.container_insights_log_group_names,
  )
}
