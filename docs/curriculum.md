# EKS 학습 커리큘럼 로드맵

매일 한 계층씩. 각 Day는 30분~1시간 분량을 목표로 하며, 앞 계층 위에 코드를 쌓아 올립니다.
"개념 이해 → 코드 작성 → apply로 관찰 → destroy로 정리"의 반복입니다.

> **이 파일이 진행 상황의 단일 기준점입니다.** Day를 마치면 여기서만 표시를 갱신하세요.
> 표기: `✅` 완료 · `🟢 (현재)` 진행 중 · 표시 없음 = 예정

---

## Phase 0 — 기반 (Foundation)

### Day 0 — 원격 state ✅ (선행 완료)
여러 맥북에서 같은 인프라를 다루기 위한 기반. 원래 Day 12 주제였습니다.
- state가 무엇이고 왜 git에 올리면 안 되는지
- S3 백엔드 + `use_lockfile` 네이티브 락 (DynamoDB 불필요)
- 📄 상세: [remote-state.md](remote-state.md)

### Day 1 — 네트워크 계층 ✅
EKS가 올라갈 **VPC 네트워크**를 만듭니다. K8s 이전의 순수 AWS 인프라.
- VPC, CIDR 블록 개념
- 퍼블릭/프라이빗 서브넷과 AZ(가용영역) 분산
- 인터넷 게이트웨이(IGW), NAT 게이트웨이, 라우트 테이블
- EKS가 요구하는 서브넷 태그의 의미
- 📄 상세: [day-01-network.md](day-01-network.md)

### Day 2 — EKS 컨트롤플레인 ✅
관리형 쿠버네티스 API 서버(컨트롤플레인) 생성.
- `aws_eks_cluster`, 클러스터가 쓰는 IAM 역할 (신뢰 정책 vs 권한 정책)
- 컨트롤플레인 ↔ 노드 통신, 클러스터 보안그룹
- 클러스터 엔드포인트(퍼블릭/프라이빗) 개념, ENI와의 차이
- 📄 상세: [day-02-eks-controlplane.md](day-02-eks-controlplane.md)

### Day 3 — 노드 그룹 (워커 노드) ✅
실제 파드가 돌아갈 컴퓨트.
- Managed Node Group vs self-managed vs Fargate 개념 비교
- `aws_eks_node_group`, 노드용 IAM 역할(신뢰 서비스가 `ec2.amazonaws.com`), 인스턴스 타입/스케일 설정
- 노드가 클러스터에 조인되는 원리, 정책 3개가 각각 없으면 깨지는 것
- ASG vs 스케줄러 vs 오토스케일러 — 누가 무엇을 결정하는가
- 📄 상세: [day-03-nodegroup.md](day-03-nodegroup.md)

### Day 4 — 접근 제어 (kubectl & IAM) ✅
내 손에서 클러스터를 조작하고, **남에게 권한을 주는 법**을 배웁니다.
- `aws eks update-kubeconfig`로 kubeconfig 구성 → `kubectl get nodes` 첫 성공
- kubectl 인증 원리 — exec 플러그인, presigned STS URL ("토큰은 신분증이지 권한증이 아니다")
- EKS Access Entries (구 aws-auth ConfigMap) — IAM ↔ K8s 신원 번역표
- Access Entry(인증) vs 액세스 정책(인가)의 분리
- 실습: 읽기 전용 IAM 역할을 만들어 `Forbidden` 직접 확인
- 📄 상세: [day-04-access-control.md](day-04-access-control.md)

> **Phase 0 완료** — 네트워크 → 컨트롤플레인 → 노드 → 접근 제어까지 기반이 갖춰졌습니다.

---

## Phase 1 — 워크로드 & 애드온

> **전제**: Namespace / Deployment / Service / Pod 같은 기본 오브젝트는 이미 아는 것으로 봅니다.
> 그래서 "첫 워크로드 배포" 같은 입문 단계는 건너뛰고, **EKS 고유의 문제**에 집중합니다.

### Day 5 — ECR + Helm으로 내 앱 배포 ✅
공개 이미지가 아니라 **내가 만든 이미지와 차트**를 EKS에 올립니다.
- ECR 리포지토리 (Terraform) — 이미지용 + **차트용(OCI 아티팩트)**
- `aws ecr get-login-password`가 왜 임시 토큰인지 (Day 4의 STS와 같은 맥락)
- 아키텍처 정합성 — 노드를 **Graviton(arm64)** 으로 맞춰 맥북과 일치시켰습니다.
  덕분에 `--platform` 플래그가 불필요합니다 (불일치 시 `exec format error`)
- `helm package` → `helm push oci://...` → `helm install oci://...`
- 노드가 정말 ECR에서 pull하는지 확인 — **Day 3의 `ECRReadOnly` 정책 실증**
- 이미지 태그 전략(`latest`가 위험한 이유), `imagePullPolicy` 캐시 함정
- push해도 자동 배포되지 않는 이유 → GitOps가 필요한 지점
- 📄 상세: [day-05-ecr-helm.md](day-05-ecr-helm.md)

### Day 6 — 핵심 애드온 이해 ✅
**CNI는 AWS VPC CNI를 사용합니다.** (검토 완료 — 이 리포는 VPC CNI로 확정)

- VPC CNI, CoreDNS, kube-proxy — EKS의 3대 필수 애드온
- **파드가 VPC IP를 받는 원리** — ENI의 보조 IP를 파드 veth에 할당
- **최대 파드 수 제약** — `(ENI 수 × (ENI당 IP − 1)) + 2`.
  t4g.medium은 3×(6−1)+2 = **17개**. CPU·메모리가 남아도 IP가 없으면 Pending
- **서브넷 IP 고갈** — 파드마다 VPC IP를 쓰므로 CIDR 사이징이 중요
- **워밍풀** (`WARM_ENI_TARGET`) — 파드 기동 속도와 IP 낭비의 트레이드오프
- **접두사 위임** (`ENABLE_PREFIX_DELEGATION`) — `/28` 블록 할당으로 최대 파드 수 확대
- **VPC CNI라서 가능한 것들**: 파드 단위 보안그룹(`ENABLE_POD_ENI`),
  ALB `target-type: ip`, VPC Flow Logs에서 파드 트래픽 관측
- **kube-proxy** — ClusterIP가 실제 파드 IP로 바뀌는 경로 (iptables 체인)
- **CoreDNS** — 서비스 디스커버리. 유일하게 DaemonSet이 아닌 Deployment인 이유
- **관리형 애드온** — `aws_eks_addon`으로 버전을 명시적으로 고정·업그레이드
  (자동 설치돼 있지만 등록 전에는 자체 관리 상태. 등록은 "관리 방식 전환")
- 📄 상세: [day-06-addons.md](day-06-addons.md)

### Day 7 — IRSA / Pod Identity 🟢 (현재)
- 파드에 AWS 권한을 안전하게 부여하는 방법
- OIDC provider, `aws_iam_role`의 신뢰 정책
- **왜 필요한가**: 지금은 노드 역할의 권한을 그 노드의 모든 파드가 공유합니다
  (Day 3에서 확인한 문제)
- IRSA vs EKS Pod Identity 비교

### Day 8 — Gateway API + AWS Load Balancer Controller
**Ingress가 아니라 Gateway API로 갑니다.**
- Ingress API는 **동결(frozen)** 상태 — GA지만 신규 기능이 들어가지 않습니다
- AWS Load Balancer Controller가 **2026년 초 Gateway API GA 지원** (LBC v3.4.0)
- NGINX Ingress Controller **2026 Q1 EOL** — 마이그레이션 수요의 배경
- GatewayClass / Gateway / HTTPRoute 구조와 Ingress 대비 무엇이 나아졌는지
  (역할 분리: 인프라팀은 Gateway, 앱팀은 Route)
- Helm으로 컨트롤러 설치 → Gateway API로 ALB 자동 생성
- Ingress는 **비교·마이그레이션 관점으로만** 다룹니다

---

## Phase 2 — 운영 심화

### Day 9 — 스토리지 (EBS/EFS CSI)
- PersistentVolume / PVC / StorageClass
- EBS CSI 드라이버로 동적 볼륨 프로비저닝
- CSI 드라이버가 IRSA를 쓰는 구조 (Day 7과 연결)

### Day 10 — 오토스케일링
- HPA(파드 수평 확장)
- **Cluster Autoscaler vs Karpenter** — Day 3에서 본 ASG를 쓰는 쪽과 안 쓰는 쪽
- Terraform과 오토스케일러의 `desired_size` 충돌 → `ignore_changes`

### Day 11 — 관측성 (Observability)
- CloudWatch Container Insights / metrics-server
- 컨트롤플레인 로그 (`enabled_cluster_log_types`) — Day 2에서 비용 때문에 꺼둔 것
- 로그/메트릭 수집 구조

### Day 12 — 리팩터링: 모듈화 & 환경 분리
- 지금까지의 코드를 Terraform 모듈로 정리
- 여러 환경(dev/prod) 구성 전략 — 백엔드 `key`를 나누거나 workspace 활용
- ~~S3 원격 백엔드로 state 관리~~ → ✅ **선행 완료**: [remote-state.md](remote-state.md)
  (맥북 여러 대에서 작업하게 되어 앞당겨 적용했습니다)

---

## 이후 심화 주제 (선택)

- GitOps (ArgoCD/Flux) — Day 5의 Helm 차트를 ArgoCD로 배포
- 네트워크 정책 / 보안 (Network Policy, Pod Security Standards)
- 서비스 메시 개요
- 비용 최적화 (Spot, 우측 사이징)
  - ~~Graviton~~ → ✅ **선행 적용**: Day 3 노드를 t4g.medium(arm64)으로 전환.
    맥북과 아키텍처가 일치해 빌드가 단순해지고 20% 저렴합니다
- 업그레이드 전략 (클러스터/노드 버전 업, 표준 지원 → 연장 지원 요금 급등 주의)

---

## 진행 팁

- 각 Day 끝에 **꼭 `terraform destroy`** — 비용의 대부분(EKS 컨트롤플레인, NAT)이 시간당 과금입니다.
- `terraform plan`을 apply 전에 항상 읽어보세요. "무엇이 왜 만들어지는지" 이해가 핵심입니다.
- 막히면 그날의 `docs/day-XX-*.md` 노트를 참고하세요.
