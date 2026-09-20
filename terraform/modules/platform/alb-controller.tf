# ============================================================================
# Day 8 — AWS Load Balancer Controller (Gateway API)
#
# 지금 앱은 ClusterIP Service라 `kubectl port-forward`로만 접근됩니다.
# 인터넷에 노출하려면 실제 로드밸런서(ALB)가 필요한데, 쿠버네티스가 직접
# AWS ALB를 만들 수는 없습니다. 그 일을 해주는 컨트롤러를 클러스터 안에 설치합니다.
#
# [흐름]
#   내가 Gateway/HTTPRoute 오브젝트를 만들면
#     → 컨트롤러가 그걸 보고
#       → AWS API를 호출해 실제 ALB를 생성·설정
#
# [Terraform이 하는 일 / 하지 않는 일]
#   여기(Terraform)  : 컨트롤러가 AWS를 조작할 권한 (IAM 역할 + Pod Identity 연결)
#   Helm             : 컨트롤러 자체 설치
#   kubectl          : Gateway API CRD, Gateway/HTTPRoute 오브젝트
#
# 💸 ALB가 생기면 시간당 약 $0.0225 + LCU + 퍼블릭 IPv4(AZ당 $0.005)가 추가됩니다.
#    이 파일 자체(IAM)는 무료입니다.
# ============================================================================

# ----------------------------------------------------------------------------
# 1) 컨트롤러가 쓸 IAM 정책
#
# 정책을 직접 쓰지 않고 **공식 정책 파일을 그대로** 씁니다.
#   출처: kubernetes-sigs/aws-load-balancer-controller v3.5.0 docs/install/iam_policy.json
#   내용: Statement 16개 / Action 80개
#         elasticloadbalancing 40 · ec2 22 · wafv2 4 · shield 4 · waf-regional 4 · iam 3 · acm 2 · cognito-idp 1
#
# 왜 직접 안 쓰는가: ALB/NLB를 만들려면 리스너·타깃그룹·보안그룹·인증서까지
# 건드려야 해서 권한 목록이 방대하고, 컨트롤러 버전이 올라가면 필요 권한도 바뀝니다.
# 직접 추려 쓰면 "권한이 없어서 되다 안 되는" 디버깅에 시간을 버립니다.
#
# iam:CreateServiceLinkedRole이 포함된 점에 주목하세요 —
# ELB 서비스가 처음 쓰일 때 AWS가 내부용 역할을 만들어야 하기 때문입니다.
# ----------------------------------------------------------------------------
resource "aws_iam_policy" "alb_controller" {
  name        = "${var.project}-alb-controller-policy"
  description = "AWS Load Balancer Controller 공식 정책 (v3.5.0)"
  policy      = file("${path.module}/policies/alb-controller-policy.json")

  tags = {
    Name = "${var.project}-alb-controller-policy"
  }
}

# ----------------------------------------------------------------------------
# 2) 역할 + Pod Identity 연결 — 재사용 모듈로
#
# [Day 12 전]  aws_iam_role + aws_iam_role_policy_attachment + association 3개를 직접 작성
# [Day 12 후]  modules/pod-identity-role 호출 한 번
#
# 위에서 만든 정책(aws_iam_policy.alb_controller)은 이 컨트롤러 전용이라 여기 남기고,
# ARN만 모듈에 넘깁니다. "무엇이 공통이고 무엇이 개별인가"를 나눈 결과입니다.
#
# [순서 주의] 연결은 SA가 아직 없어도 만들어집니다 —
# AWS는 쿠버네티스 쪽에 그 SA가 실제로 있는지 검사하지 않습니다.
# 그래서 "먼저 권한을 준비하고 → Helm으로 설치" 순서가 가능합니다.
# ----------------------------------------------------------------------------
module "alb_controller_role" {
  source = "../pod-identity-role"

  project             = var.project
  name                = "alb-controller"
  cluster_name        = var.cluster_name
  namespace           = "kube-system"
  service_account     = "aws-load-balancer-controller" # Helm 차트가 만드는 SA 이름
  managed_policy_arns = { alb-controller = aws_iam_policy.alb_controller.arn }

  # 연결(association)은 에이전트가 설치된 뒤에 만들어야 합니다.
  # 모듈 블록에도 depends_on을 걸 수 있습니다 — 모듈 안 리소스 전체가 기다립니다.
  depends_on = [aws_eks_addon.pod_identity]
}
