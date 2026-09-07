# Terraform 자체 버전과 사용할 provider 버전을 고정합니다.
# 버전을 고정하면 "내 PC에서 되던 게 나중엔 안 되는" 문제를 예방합니다.

terraform {
  # S3 네이티브 락(use_lockfile)을 쓰기 위해 1.11 이상이 필요합니다.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # 5.x 최신을 사용 (6.0 미만)
    }
  }

  # --------------------------------------------------------------------------
  # 원격 state (S3 백엔드)
  #
  # [왜 원격인가]
  # state는 "AWS에 무엇이 실제로 존재하는지"에 대한 유일한 기록입니다.
  # 로컬 파일에 두면 맥북 A에서 만든 리소스를 맥북 B가 알 수 없어,
  # 중복 생성되거나 destroy해도 안 지워지는 고아 리소스(=계속 과금)가 생깁니다.
  # git으로 state를 동기화하는 건 답이 아닙니다 — state는 병합이 불가능하고,
  # 비밀번호/키가 평문으로 들어 있어 저장소에 올리면 그대로 노출됩니다.
  #
  # [use_lockfile]
  # 두 기기에서 동시에 apply하는 걸 막는 잠금장치입니다.
  # 예전엔 DynamoDB 테이블이 따로 필요했지만, Terraform 1.11부터 S3 자체 락을
  # 지원해서 테이블 없이 이 한 줄이면 됩니다. (S3에 .tflock 파일로 구현됨)
  #
  # [이 버킷은 destroy 대상이 아닙니다]
  # 매일 apply/destroy하는 리소스와 달리, 버킷은 Terraform 바깥에서 1회 생성해
  # 계속 유지합니다. state를 담는 그릇이 state와 함께 사라지면 안 되니까요.
  # 버전 관리 + 암호화 + 퍼블릭 차단이 적용되어 있습니다.
  # --------------------------------------------------------------------------
  backend "s3" {
    bucket       = "deepagent-eks-tfstate"
    key          = "eks-lab/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
