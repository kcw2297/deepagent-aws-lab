# Terraform 자체 버전과 사용할 provider 버전을 고정합니다.
# 버전을 고정하면 "내 PC에서 되던 게 나중엔 안 되는" 문제를 예방합니다.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # 5.x 최신을 사용 (6.0 미만)
    }
  }

  # [학습 노트] 지금은 state를 로컬 파일(terraform.tfstate)에 저장합니다.
  # 혼자 학습 + 매일 destroy 하는 환경에선 이걸로 충분합니다.
  # Day 12에서 S3 + DynamoDB 원격 백엔드로 바꿔볼 예정입니다.
  # backend "s3" { ... }  <- 나중에 활성화
}
