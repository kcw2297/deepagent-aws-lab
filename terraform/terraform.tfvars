# 변수 실제 값. variables.tf의 default를 덮어씁니다.
# 기본값을 그대로 써도 되지만, 여기서 명시적으로 관리하면 무엇을 쓰는지 한눈에 보입니다.

region  = "ap-northeast-2"
project = "deepagent-eks-lab"

vpc_cidr = "10.0.0.0/16"

azs                  = ["ap-northeast-2a", "ap-northeast-2c"]
public_subnet_cidrs  = ["10.0.0.0/20", "10.0.16.0/20"]
private_subnet_cidrs = ["10.0.32.0/20", "10.0.48.0/20"]
