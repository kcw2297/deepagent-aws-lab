# platform 모듈의 입력.
#
# 이 모듈은 "클러스터 위에 올라가는 것들"을 담습니다 —
# 애드온, 컨트롤러 권한, 스토리지, 오토스케일링, 관측성.
# 클러스터 자체는 만들지 않고, 이름과 OIDC 정보만 받아서 씁니다.

variable "project" {
  description = "리소스 이름/태그 접두사"
  type        = string
}

variable "cluster_name" {
  description = "애드온과 Pod Identity 연결을 붙일 클러스터 이름 (cluster 모듈의 출력)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "IRSA 데모 역할의 신뢰 정책에 쓰는 OIDC provider ARN (cluster 모듈의 출력)"
  type        = string
}

variable "oidc_issuer_host" {
  description = "IRSA 신뢰 정책 조건 키에 쓰는 OIDC 발급자 호스트 (cluster 모듈의 출력)"
  type        = string
}

# ---------- 애드온 버전 (Day 6·7·9·10·11) ----------
# 버전을 코드에 명시하는 이유는 versions.tf에서 provider를 고정한 것과 같습니다.
#   aws eks describe-addon-versions --addon-name <이름> --kubernetes-version <버전>

variable "addon_version_vpc_cni" {
  description = "VPC CNI 애드온 버전"
  type        = string
}

variable "addon_version_kube_proxy" {
  description = "kube-proxy 애드온 버전"
  type        = string
}

variable "addon_version_coredns" {
  description = "CoreDNS 애드온 버전"
  type        = string
}

variable "addon_version_pod_identity" {
  description = "EKS Pod Identity Agent 애드온 버전"
  type        = string
}

variable "addon_version_ebs_csi" {
  description = "EBS CSI 드라이버 애드온 버전"
  type        = string
}

variable "addon_version_metrics_server" {
  description = "metrics-server 애드온 버전 (HPA의 전제)"
  type        = string
}

variable "addon_version_cloudwatch_observability" {
  description = "amazon-cloudwatch-observability 애드온 버전"
  type        = string
}

variable "log_retention_days" {
  description = "Container Insights 로그 그룹 보관 기간(일)"
  type        = number
}
