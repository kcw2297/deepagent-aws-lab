# platform 모듈의 출력.
# 대부분 "kubectl/Helm 실습에서 손으로 써야 하는 값"들입니다.

output "addon_versions" {
  description = "Terraform이 관리하는 애드온 버전"
  value = {
    vpc_cni    = aws_eks_addon.vpc_cni.addon_version
    kube_proxy = aws_eks_addon.kube_proxy.addon_version
    coredns    = aws_eks_addon.coredns.addon_version
  }
}

output "irsa_demo_role_arn" {
  description = "IRSA 실습용 역할 (ServiceAccount 애노테이션에 넣는 값)"
  value       = aws_iam_role.irsa_demo.arn
}

output "pod_identity_demo_role_arn" {
  description = "Pod Identity 실습용 역할 (애노테이션 불필요)"
  value       = aws_iam_role.pod_identity_demo.arn
}

output "alb_controller_role_arn" {
  description = "LB Controller가 쓰는 IAM 역할"
  value       = module.alb_controller_role.role_arn
}

output "ebs_csi_role_arn" {
  description = "EBS CSI 컨트롤러가 쓰는 IAM 역할"
  value       = module.ebs_csi_role.role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "Cluster Autoscaler가 쓰는 IAM 역할"
  value       = module.cluster_autoscaler_role.role_arn
}

output "cloudwatch_agent_role_arn" {
  description = "CloudWatch Agent·Fluent Bit이 쓰는 IAM 역할"
  value       = module.cloudwatch_agent_role.role_arn
}

output "container_insights_log_group_names" {
  description = "Container Insights 로그 그룹 (destroy 시 함께 삭제)"
  value       = [for g in aws_cloudwatch_log_group.container_insights : g.name]
}
