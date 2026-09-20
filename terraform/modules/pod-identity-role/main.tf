# ============================================================================
# 재사용 모듈 — Pod Identity용 IAM 역할
#
# [왜 모듈로 뽑았나]
# Day 8~11에서 컨트롤러를 추가할 때마다 똑같은 세 덩어리를 썼습니다:
#
#   ① 역할          : 신뢰 대상이 pods.eks.amazonaws.com 으로 항상 동일
#   ② 권한          : 관리형 정책 ARN을 붙이거나, 인라인 정책을 직접 쓰거나
#   ③ 연결(association) : "이 네임스페이스의 이 SA가 이 역할을 쓴다"
#
#   Day 8  LB Controller  ①+②(직접 만든 정책)+③
#   Day 9  EBS CSI        ①+②(관리형 정책)      ③은 애드온 안에서
#   Day 10 Cluster Autoscaler ①+②(인라인 정책)  +③
#   Day 11 CloudWatch Agent   ①+②(관리형 정책)  ③은 애드온 안에서
#
# 4번 반복되는 걸 **직접 겪은 뒤에** 묶는 것이라, 무엇을 입력으로 뺄지 알 수 있습니다.
# (처음부터 모듈로 만들었다면 ③이 두 가지 방식이라는 것도 몰랐을 겁니다)
#
# [모듈의 인터페이스 = variables.tf + outputs.tf]
# 이 파일 안의 리소스는 밖에서 직접 참조할 수 없습니다.
# 쓰는 쪽은 outputs.tf에 내보낸 role_arn 만 봅니다.
# ============================================================================

# ① 역할 — 신뢰 정책은 어느 컨트롤러든 완전히 같습니다.
#    sts:TagSession이 함께 필요한 이유는 Day 7 노트를 보세요
#    (Pod Identity가 세션에 네임스페이스/SA를 태그로 심습니다).
resource "aws_iam_role" "this" {
  name = "${var.project}-${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = {
    Name = "${var.project}-${var.name}-role"
  }
}

# ②-a 관리형 정책 붙이기 (Day 9 EBS CSI, Day 11 CloudWatch Agent 방식)
#
# for_each를 쓰면 정책이 0개든 3개든 같은 코드로 처리됩니다.
# count를 쓰면 목록 중간에서 하나를 빼는 순간 뒤의 인덱스가 전부 밀려
# 멀쩡한 리소스가 재생성됩니다.
#
# [입력이 list가 아니라 map인 이유 — Day 12에서 실제로 겪은 에러]
# 처음엔 list(string)에 toset()을 씌웠는데 plan이 이렇게 거부했습니다:
#
#   Error: Invalid for_each argument
#   The "for_each" set includes values derived from resource attributes that
#   cannot be determined until apply
#
# Day 8 LB Controller의 정책은 우리가 만드는 aws_iam_policy라서, ARN이 apply 전에는
# 미정입니다. set으로 쓰면 **값이 곧 키**라서 Terraform이 "몇 개짜리 무엇이 생길지"를
# plan 시점에 모릅니다. map으로 받으면 키는 우리가 코드에 적은 고정 문자열이고
# 값(ARN)만 나중에 정해지므로 plan이 가능합니다.
#
#   ❌ for_each = toset([aws_iam_policy.x.arn])      키가 미정
#   ✅ for_each = { alb = aws_iam_policy.x.arn }     키는 "alb", 값만 미정
resource "aws_iam_role_policy_attachment" "managed" {
  for_each = var.managed_policy_arns

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

# ②-b 인라인 정책 (Day 10 Cluster Autoscaler 방식)
#
# 관리형 정책이 없거나, 태그 조건 같은 걸 직접 걸어야 할 때 씁니다.
# 넘기지 않으면(null) 만들어지지 않습니다.
resource "aws_iam_role_policy" "inline" {
  count = var.inline_policy == null ? 0 : 1

  name   = var.name
  role   = aws_iam_role.this.id
  policy = var.inline_policy
}

# ③ 연결 — "어느 SA가 이 역할을 쓰는가"
#
# [끄는 경우가 있습니다]
# 관리형 애드온(EBS CSI, CloudWatch)은 애드온 리소스 안에 pod_identity_association
# 블록을 쓸 수 있어서, 여기서 또 만들면 같은 연결이 두 번 생깁니다.
# 그런 경우 create_association = false 로 두고 역할만 받아 갑니다.
resource "aws_eks_pod_identity_association" "this" {
  count = var.create_association ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn

  tags = {
    Name = "${var.project}-${var.name}-podid"
  }
}
