# ============================================================================
# dev 환경 — 루트 모듈
#
# [루트 모듈이 하는 일: 조립만]
# 리소스를 직접 만들지 않습니다. 모듈 3개를 부르고, 값을 넘기고, 이어붙입니다.
# "무엇이 만들어지는가"는 modules/ 안에, "어떤 값으로 만들어지는가"는 tfvars에.
#
#   network   Day 1        VPC·서브넷·NAT·라우팅
#   cluster   Day 2~4,7,11 컨트롤플레인·노드그룹·접근제어·OIDC·컨트롤플레인 로그
#   platform  Day 6~11     애드온·컨트롤러 권한·스토리지·오토스케일링·관측성
#
# 의존 방향은 한쪽입니다: network → cluster → platform
# 반대 방향 참조가 생기면 Terraform이 순환이라고 거부합니다.
# (실제로 Day 12 작업 중 컨트롤플레인 로그 그룹에서 이 문제가 드러나 cluster로 옮겼습니다)
# ============================================================================

locals {
  # [왜 여기서 이름을 정하나]
  # network 모듈의 서브넷 태그(kubernetes.io/cluster/<이름>)와
  # cluster 모듈의 클러스터 이름이 같아야 합니다.
  # 클러스터 모듈의 output에서 받으면 network가 cluster에 의존하게 되어 순환입니다.
  # 이름은 계산이 필요 없는 값이므로 루트에서 정해 양쪽에 넘깁니다.
  cluster_name = "${var.project}-cluster"
}

module "network" {
  source = "../../modules/network"

  project      = var.project
  cluster_name = local.cluster_name

  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

module "cluster" {
  source = "../../modules/cluster"

  project      = var.project
  cluster_name = local.cluster_name

  # 모듈 사이를 잇는 유일한 통로 — network의 output을 cluster의 input으로
  private_subnet_ids = module.network.private_subnet_ids

  kubernetes_version          = var.kubernetes_version
  cluster_public_access_cidrs = var.cluster_public_access_cidrs

  node_instance_type = var.node_instance_type
  node_ami_type      = var.node_ami_type
  node_desired_size  = var.node_desired_size
  node_min_size      = var.node_min_size
  node_max_size      = var.node_max_size
  node_disk_size     = var.node_disk_size

  cluster_log_types  = var.cluster_log_types
  log_retention_days = var.log_retention_days
}

module "platform" {
  source = "../../modules/platform"

  project           = var.project
  cluster_name      = module.cluster.cluster_name
  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_issuer_host  = module.cluster.oidc_issuer_host

  addon_version_vpc_cni                  = var.addon_version_vpc_cni
  addon_version_kube_proxy               = var.addon_version_kube_proxy
  addon_version_coredns                  = var.addon_version_coredns
  addon_version_pod_identity             = var.addon_version_pod_identity
  addon_version_ebs_csi                  = var.addon_version_ebs_csi
  addon_version_metrics_server           = var.addon_version_metrics_server
  addon_version_cloudwatch_observability = var.addon_version_cloudwatch_observability

  log_retention_days = var.log_retention_days

  # [모듈 단위 depends_on]
  # 애드온과 컨트롤러는 노드가 있어야 파드를 띄울 수 있습니다.
  # 모듈화 전에는 리소스마다 depends_on = [aws_eks_node_group.this] 를 달았지만,
  # 이제 모듈 전체가 cluster 모듈을 기다립니다 — 개별 리소스를 알 필요가 없어졌습니다.
  depends_on = [module.cluster]
}
