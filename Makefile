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
# 쿠버네티스 오브젝트가 만든 AWS 리소스는 **Terraform state에 없습니다.**
#   Day 8  Gateway → ALB · 리스너 · 타깃 그룹 · 보안그룹   (LB Controller가 생성)
#   Day 9  PVC     → EBS 볼륨                           (EBS CSI 드라이버가 생성)
# terraform destroy는 그 존재를 모릅니다.
#
# 그냥 destroy하면:
#   ① 노드 그룹·애드온 삭제 → 컨트롤러·드라이버 파드 사망
#   ② ALB·EBS를 지워줄 주체가 사라짐
#   ③ ALB의 ENI가 서브넷 삭제를 막아 destroy가 멈춤 (EBS는 조용히 남아 과금)
#   → 고아 리소스가 계속 과금 💸  (2026-09-09 ALB로 실제로 겪었습니다)
#
# 그래서 아래 순서를 강제합니다:
#   ① 쿠버네티스 오브젝트 삭제  → 컨트롤러·드라이버가 AWS 리소스를 정리하게 함
#   ② AWS 리소스가 0이 될 때까지 대기   ← 9월 9일에 빠졌던 단계
#   ③ Helm으로 설치한 컨트롤러 제거
#   ④ terraform destroy
#
# ①을 전부 먼저 하고 ②에서 함께 기다리는 이유: ALB와 EBS 삭제는 서로 무관해서
# 병렬로 진행됩니다. 하나씩 기다리면 시간만 두 배로 듭니다.
#
# 해당 Day의 리소스가 없는 세션에서도 안전합니다 — 없으면 그냥 넘어갑니다.
# (명령 앞의 `-`는 실패해도 계속 진행하라는 make 문법입니다)
# ----------------------------------------------------------------------------
destroy:
	@echo "── ① 쿠버네티스 오브젝트 삭제"
	@echo "   Day 8 Gateway (→ LB Controller가 ALB 정리)"
	-@kubectl delete -f k8s/day08/ --ignore-not-found=true --timeout=120s 2>/dev/null || echo "     (없음 — 건너뜁니다)"
	@echo "   Day 9 PVC와 그 워크로드 (→ EBS CSI가 볼륨 정리)"
	@# PVC는 파드가 쓰는 중이면 지워지지 않습니다(pvc-protection finalizer).
	@# 그래서 워크로드와 PVC가 함께 든 파일을 지웁니다. kubectl이 완료까지 기다립니다.
	-@kubectl delete -f k8s/day09/pvc-test.yaml --ignore-not-found=true --timeout=120s 2>/dev/null || echo "     (없음 — 건너뜁니다)"
	@echo "── ② AWS 리소스가 사라질 때까지 대기 (최대 3분)"
	@i=0; while [ $$i -lt 18 ]; do \
	  alb=$$(aws elbv2 describe-load-balancers --region $(REGION) --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0); \
	  ebs=$$(aws ec2 describe-volumes --region $(REGION) --filters Name=tag-key,Values=ebs.csi.aws.com/cluster --query 'length(Volumes)' --output text 2>/dev/null || echo 0); \
	  if [ "$$alb" = "0" ] && [ "$$ebs" = "0" ]; then echo "   ALB 0개 · PVC용 EBS 0개 확인 ✅"; break; fi; \
	  echo "   남은 ALB: $$alb · PVC용 EBS: $$ebs ... 대기"; sleep 10; i=$$((i+1)); \
	done; \
	if [ $$i -ge 18 ]; then echo "   ⚠️ 시간 초과. 남은 리소스가 있으면 destroy가 실패하거나 과금이 계속됩니다"; fi
	@echo "── ③ Helm으로 설치한 컨트롤러 제거"
	-@helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || echo "   (없음 — 건너뜁니다)"
	@echo "── ④ terraform destroy"
	$(TF) destroy
