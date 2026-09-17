# ============================================================================
# deepagent-aws-lab — 학습 세션용 단축 명령
#
# 매번 `cd terraform` 하지 않고 리포 루트에서 바로 실행합니다.
# (terraform의 -chdir 옵션을 쓰므로 실제로 디렉터리를 옮기지 않습니다)
#
#   하루 시작:  make apply
#   하루 마무리: make destroy   ← 반드시! 비용이 시간당 발생합니다
# ============================================================================

TF_DIR := terraform
TF     := terraform -chdir=$(TF_DIR)
REGION := ap-northeast-2

# 인자 없이 `make`만 치면 사용법을 보여줍니다.
.DEFAULT_GOAL := help

.PHONY: help init plan apply destroy

help:
	@echo ""
	@echo "  make init      백엔드(S3) 연결 + provider 설치 — 새 맥북에서 1회"
	@echo "  make plan      무엇이 왜 만들어지는지 미리보기 (apply 전에 꼭 읽기)"
	@echo "  make apply     인프라 생성 — 오늘의 학습 시작"
	@echo "  make destroy   인프라 정리 — 오늘의 학습 끝 (비용 차단)"
	@echo ""
	@echo "  apply 후에는 kubeconfig 갱신이 필요합니다 (엔드포인트가 새로 발급됨):"
	@echo "    aws eks update-kubeconfig --region $(REGION) \\"
	@echo "      --name \$$($(TF) output -raw cluster_name)"
	@echo ""
	@echo "  state는 S3(deepagent-eks-tfstate)에 있어 맥북 2대가 같은 것을 봅니다."
	@echo "  자세히: docs/remote-state.md"
	@echo ""

# 새 기기에서 클론한 직후, 또는 provider/백엔드 설정이 바뀌었을 때 실행합니다.
init:
	$(TF) init

# plan은 아무것도 바꾸지 않는 읽기 전용입니다. 부담 없이 자주 돌려보세요.
# "코드 ↔ state ↔ 실제 AWS"의 차이를 보여줍니다.
plan:
	$(TF) plan

# apply/destroy는 terraform이 yes 확인을 받습니다. 그 확인 문구를 꼭 읽어보세요.
apply:
	$(TF) apply

# ----------------------------------------------------------------------------
# destroy — 순서가 중요합니다
#
# [왜 단순히 terraform destroy가 아닌가]
# Day 8부터 "쿠버네티스 오브젝트가 만든 AWS 리소스"가 생깁니다.
#   Gateway  → ALB · 리스너 · 타깃 그룹 · 보안그룹 2개
# 이것들은 LB Controller가 만들었으므로 **Terraform state에 없습니다.**
# terraform destroy는 그 존재를 모릅니다.
#
# 그냥 destroy하면:
#   ① 노드 그룹 삭제 → 컨트롤러 파드 사망
#   ② ALB를 지워줄 주체가 사라짐
#   ③ ALB의 ENI가 서브넷 삭제를 막아 destroy가 중간에 멈춤
#   → 고아 ALB가 남아 계속 과금 💸  (2026-09-09에 실제로 겪었습니다)
#
# 그래서 아래 순서를 강제합니다:
#   ① Gateway 오브젝트 삭제 → 컨트롤러가 ALB를 정리하게 함
#   ② ALB가 정말 0이 될 때까지 대기      ← 9월 9일에 빠졌던 단계
#   ③ 컨트롤러 제거
#   ④ terraform destroy
#
# Day 8 리소스가 없는 세션에서도 안전합니다 — 각 단계가 없으면 그냥 넘어갑니다.
# (명령 앞의 `-`는 실패해도 계속 진행하라는 make 문법입니다)
# ----------------------------------------------------------------------------
destroy:
	@echo "── ① Gateway 오브젝트 삭제 (컨트롤러가 ALB를 정리합니다)"
	-@kubectl delete -f k8s/day08/ --ignore-not-found=true 2>/dev/null || echo "   (없음 — 건너뜁니다)"
	@echo "── ② ALB가 사라질 때까지 대기 (최대 3분)"
	@i=0; while [ $$i -lt 18 ]; do \
	  n=$$(aws elbv2 describe-load-balancers --region $(REGION) --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0); \
	  if [ "$$n" = "0" ]; then echo "   ALB 0개 확인 ✅"; break; fi; \
	  echo "   남은 ALB: $$n ... 대기"; sleep 10; i=$$((i+1)); \
	done; \
	if [ $$i -ge 18 ]; then echo "   ⚠️ 시간 초과. ALB가 남아 있으면 destroy가 실패할 수 있습니다"; fi
	@echo "── ③ LB Controller 제거"
	-@helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || echo "   (없음 — 건너뜁니다)"
	@echo "── ④ terraform destroy"
	$(TF) destroy
