# deepagent-aws-lab — EKS 학습 랩

Terraform으로 AWS EKS를 **한 계층씩 직접 만들어 보며** 구조를 익히는 학습용 리포지토리입니다.

## 학습 원칙

1. **코드는 계층별로 쌓인다** — 매일 새로운 `.tf` 파일/리소스를 추가하며 인프라를 위로 쌓아 올립니다.
2. **인프라는 매일 껐다 켠다** — 학습 세션 시작 시 `terraform apply`, 끝나면 `terraform destroy`.
   비용은 컨트롤플레인($0.10/h) + 노드 + NAT 게이트웨이 정도만, 실습 시간에만 발생합니다.
3. **직접 손으로 작성한다** — 커뮤니티 모듈로 감싸지 않고 리소스를 눈으로 보며 이해합니다.

## 환경

- Region: `ap-northeast-2` (서울)
- Terraform 1.12+, AWS Provider 5.x
- 도구: terraform, eksctl, kubectl, aws-cli (설치 완료)

## 디렉터리 구조

```
deepagent-aws-lab/
├── README.md              # 이 파일
├── docs/
│   ├── curriculum.md      # 전체 커리큘럼 로드맵 (Day별)
│   └── day-01-network.md  # Day 1 상세 학습 노트
└── terraform/
    ├── versions.tf        # Terraform/Provider 버전 고정
    ├── providers.tf       # AWS provider 설정
    ├── variables.tf       # 입력 변수 정의
    ├── terraform.tfvars   # 변수 실제 값
    ├── network.tf         # [Day 1] VPC / 서브넷 / 라우팅
    └── outputs.tf         # 출력값
```

## 매 세션 루틴

```bash
cd terraform
terraform apply      # 인프라 생성 (첫날엔 terraform init 먼저)
# ... 오늘의 학습/실습 ...
terraform destroy    # 인프라 정리 (비용 차단)
```

## 진행 상황

- [x] Day 1 — 네트워크 계층 (VPC, 서브넷, IGW, NAT, 라우팅)
- [ ] Day 2 — EKS 컨트롤플레인 (클러스터)
- [ ] Day 3 — 노드 그룹 (워커 노드)
- [ ] Day 4 — kubectl 접근 & IAM 인증 (access entries)
- [ ] Day 5 — 첫 워크로드 배포 (Deployment/Service)
- [ ] 이후 — 애드온, 로드밸런서, 스토리지, 오토스케일링, IRSA, 관측성

자세한 내용은 [docs/curriculum.md](docs/curriculum.md) 참고.
