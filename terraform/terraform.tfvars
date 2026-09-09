# 변수 실제 값. variables.tf의 default를 덮어씁니다.
# 기본값을 그대로 써도 되지만, 여기서 명시적으로 관리하면 무엇을 쓰는지 한눈에 보입니다.

region  = "ap-northeast-2"
project = "deepagent-eks-lab"

vpc_cidr = "10.0.0.0/16"

azs                  = ["ap-northeast-2a", "ap-northeast-2c"]
public_subnet_cidrs  = ["10.0.0.0/20", "10.0.16.0/20"]
private_subnet_cidrs = ["10.0.32.0/20", "10.0.48.0/20"]

# ---------- EKS (Day 2) ----------
kubernetes_version          = "1.36"
cluster_public_access_cidrs = ["0.0.0.0/0"]

# ---------- 노드 그룹 (Day 3) ----------
# Graviton(arm64) — 개발 머신 아키텍처와 일치시켜 --platform 문제를 없앱니다
node_instance_type = "t4g.medium"
node_ami_type      = "AL2023_ARM_64_STANDARD"
node_desired_size  = 2
node_min_size      = 1
node_max_size      = 3
node_disk_size     = 20

# ---------- 애드온 (Day 6) ----------
# 현재 클러스터에서 실행 중인 버전과 동일 → 편입해도 워크로드 재시작 없음
addon_version_vpc_cni      = "v1.22.4-eksbuild.3"
addon_version_kube_proxy   = "v1.36.0-eksbuild.17"
addon_version_coredns      = "v1.14.3-eksbuild.14"
addon_version_pod_identity = "v1.4.0-eksbuild.2"
