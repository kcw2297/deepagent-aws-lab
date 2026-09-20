# 이 파일이 모듈의 "입력 인터페이스"입니다.
# 여기 없는 값은 모듈 안에서 알 수 없습니다 — 그게 모듈 경계입니다.

variable "project" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "name" {
  description = "이 역할의 용도 이름 (예: alb-controller). 역할 이름은 <project>-<name>-role 이 됩니다."
  type        = string
}

variable "cluster_name" {
  description = "연결을 만들 EKS 클러스터 이름"
  type        = string
}

variable "namespace" {
  description = "이 역할을 쓸 ServiceAccount의 네임스페이스"
  type        = string
}

variable "service_account" {
  description = "이 역할을 쓸 ServiceAccount 이름. Helm 차트가 만드는 이름과 반드시 같아야 합니다 (Day 10에서 겪은 함정)"
  type        = string
}

variable "managed_policy_arns" {
  description = <<-EOT
    붙일 정책들. { 식별용_이름 = 정책_ARN } 형태의 map입니다.

    list가 아닌 map인 이유: ARN이 apply 전에 정해지지 않는 경우(직접 만든 aws_iam_policy)
    for_each의 키가 미정이 되어 plan이 실패합니다. 키를 코드에 고정하려고 map을 씁니다.
  EOT
  type        = map(string)
  default     = {}
}

variable "inline_policy" {
  description = "인라인 정책 JSON 문자열. 관리형 정책으로 안 되는 경우에만 씁니다 (null이면 안 만듦)"
  type        = string
  default     = null
}

variable "create_association" {
  description = "Pod Identity 연결을 이 모듈이 만들지 여부. 관리형 애드온이 직접 연결하는 경우 false"
  type        = bool
  default     = true
}
