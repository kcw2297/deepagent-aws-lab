# 이 파일이 모듈의 "출력 인터페이스"입니다.
# 쓰는 쪽은 모듈 안의 리소스가 아니라 이 값들만 참조할 수 있습니다.

output "role_arn" {
  description = "만들어진 IAM 역할 ARN"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "IAM 역할 이름"
  value       = aws_iam_role.this.name
}
