# AWS provider 설정: 어느 리전에, 어떤 자격증명으로 리소스를 만들지 정합니다.
# 자격증명은 aws-cli가 이미 구성한 것(~/.aws/credentials, 환경변수)을 자동으로 사용합니다.

provider "aws" {
  region = var.region

  # 이 스택으로 만든 모든 리소스에 공통 태그를 자동으로 붙입니다.
  # 나중에 콘솔/비용 탐색기에서 "학습용 리소스"를 쉽게 식별하기 위함입니다.
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Env       = "lab"
    }
  }
}
