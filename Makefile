TF_DIR := terraform
TF     := terraform -chdir=$(TF_DIR)

# 인자 없이 `make`만 치면 사용법을 보여줍니다.
.DEFAULT_GOAL := help

.PHONY: init plan apply destroy

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

# NAT 게이트웨이 등은 켜져 있는 동안 계속 과금됩니다. 세션 마무리에 반드시 실행합니다.
destroy:
	$(TF) destroy
