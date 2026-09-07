# deepagent-aws-lab — EKS 학습 랩

Terraform으로 AWS EKS를 **한 계층씩 직접 만들어 보며** 구조를 익히는 학습용 리포지토리입니다.

## 학습 원칙

1. **코드는 계층별로 쌓인다** — 매일 새로운 `.tf` 파일/리소스를 추가하며 인프라를 위로 쌓아 올립니다.
2. **인프라는 매일 껐다 켠다** — 학습 세션 시작 시 `terraform apply`, 끝나면 `terraform destroy`.
   비용은 컨트롤플레인($0.10/h) + 노드 + NAT 게이트웨이 정도만, 실습 시간에만 발생합니다.
3. **직접 손으로 작성한다** — 커뮤니티 모듈로 감싸지 않고 리소스를 눈으로 보며 이해합니다.
4. **state는 S3에 둔다** — 여러 맥북에서 작업하므로 원격 state가 단일 기준점입니다.
   자세히: [docs/remote-state.md](docs/remote-state.md)

## 환경

- Region: `ap-northeast-2` (서울)
- Terraform 1.11+ (S3 네이티브 락 사용), AWS Provider 5.x
- 도구: terraform, eksctl, kubectl, aws-cli
- state: S3 원격 백엔드 (`deepagent-eks-tfstate`)

## 디렉터리 구조

```
deepagent-aws-lab/
├── README.md              # 이 파일
├── CLAUDE.md              # 이 리포의 작업 규칙 (Claude Code용)
├── Makefile               # init/plan/apply/destroy 단축 명령
├── docs/
│   ├── curriculum.md      # 전체 커리큘럼 로드맵 (Day별)
│   ├── day-01-network.md  # Day 1 상세 학습 노트
│   └── remote-state.md    # 원격 state(S3 백엔드) 학습 노트
└── terraform/
    ├── versions.tf        # Terraform/Provider 버전 고정 + S3 백엔드
    ├── providers.tf       # AWS provider 설정
    ├── variables.tf       # 입력 변수 정의
    ├── terraform.tfvars   # 변수 실제 값
    ├── network.tf         # [Day 1] VPC / 서브넷 / 라우팅
    └── outputs.tf         # 출력값
```

## 새 기기에서 시작할 때 (기기당 1회)

```bash
aws configure                 # region: ap-northeast-2, output: json
aws sts get-caller-identity   # 연결 확인
make init                     # S3 백엔드 연결
```

## 매 세션 루틴

리포 루트에서 `make`로 실행합니다. (`make`만 치면 사용법이 나옵니다)

```bash
make plan       # 무엇이 왜 만들어지는지 미리보기
make apply      # 인프라 생성 — 오늘의 학습 시작
# ... 오늘의 학습/실습 ...
make destroy    # 인프라 정리 (비용 차단)
```

state는 S3에 있으므로 **git으로 주고받지 않습니다.** 어느 맥북에서든 같은 state를 봅니다.

## 진행 상황

**[docs/curriculum.md](docs/curriculum.md)** 한 곳에서만 관리합니다.
Day별 계획과 현재 위치를 그곳에서 확인하세요. (두 곳에 두면 반드시 어긋나므로 의도적으로 단일화)
