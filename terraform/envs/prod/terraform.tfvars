# prod 환경의 값.
# ⚠️ 이 환경은 학습용 리포에서 apply하지 않습니다. plan으로만 비교합니다.
#
# dev와 같은 모듈을 쓰지만 값이 다릅니다 —
# "환경 차이는 코드가 아니라 값의 차이"라는 것이 이 구성의 요점입니다.

region      = "ap-northeast-2"
project     = "deepagent-eks-prod" # 이름이 겹치면 같은 계정에서 충돌합니다
environment = "prod"

# 대역을 dev와 다르게 둡니다. 나중에 VPC 피어링/TGW로 이을 때 겹치면 안 됩니다.
vpc_cidr = "10.10.0.0/16"

azs                  = ["ap-northeast-2a", "ap-northeast-2c"]
public_subnet_cidrs  = ["10.10.0.0/20", "10.10.16.0/20"]
private_subnet_cidrs = ["10.10.32.0/20", "10.10.48.0/20"]

# ---------- EKS ----------
kubernetes_version = "1.36"
# 운영이라면 API 서버를 아무에게나 열지 않습니다. 사무실/VPN 대역으로 좁힙니다.
cluster_public_access_cidrs = ["203.0.113.0/24"] # 예시 값 (TEST-NET-3)

# ---------- 노드 그룹 ----------
# dev: t4g.medium 1~3대 / prod: 더 큰 타입에 최소 2대로 AZ 이중화
node_instance_type = "t4g.large"
node_ami_type      = "AL2023_ARM_64_STANDARD"
node_desired_size  = 3
node_min_size      = 2
node_max_size      = 6
node_disk_size     = 50

# ---------- 애드온 ----------
# 버전은 dev에서 먼저 올려 검증한 뒤 prod에 반영합니다 — 이게 환경 분리의 실제 쓸모입니다.
addon_version_vpc_cni      = "v1.22.4-eksbuild.3"
addon_version_kube_proxy   = "v1.36.0-eksbuild.17"
addon_version_coredns      = "v1.14.3-eksbuild.14"
addon_version_pod_identity = "v1.4.0-eksbuild.2"

addon_version_ebs_csi        = "v1.66.0-eksbuild.1"
addon_version_metrics_server = "v0.9.0-eksbuild.11"

# ---------- 관측성 ----------
# dev는 비용 때문에 1일, prod는 감사 추적을 위해 길게 둡니다.
cluster_log_types                      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
log_retention_days                     = 30
addon_version_cloudwatch_observability = "v6.6.0-eksbuild.1"
