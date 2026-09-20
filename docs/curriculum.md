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

### Day 7 — IRSA / Pod Identity ✅
파드에 AWS 권한을 **파드 단위로** 부여합니다.
- **IMDS와 홉 제한** — 일반 파드에 자격증명이 없는 이유 (TTL=1로 차단)
- **ServiceAccount** — 파드의 신원. 토큰의 `iss`/`sub`/`aud`
- **IRSA** — OIDC provider 등록 + `sts:AssumeRoleWithWebIdentity` + `sub` 조건
- **Pod Identity** — 에이전트 + association. OIDC·애노테이션 불필요
- 두 방식 비교 — 주입 환경변수, 세션 이름(CloudTrail 추적), 재사용성
- 실습: SA 없음 / IRSA / Pod Identity 세 파드를 나란히 비교
- 📄 상세: [day-07-irsa-pod-identity.md](day-07-irsa-pod-identity.md)

### Day 8 — Gateway API + AWS Load Balancer Controller ✅
**Ingress가 아니라 Gateway API로 갑니다.**
- Ingress API는 **동결(frozen)** 상태 — GA지만 신규 기능이 들어가지 않습니다
- AWS Load Balancer Controller가 **2026년 초 Gateway API GA 지원** (LBC v3.4.0)
- NGINX Ingress Controller **2026 Q1 EOL** — 마이그레이션 수요의 배경
- GatewayClass / Gateway / HTTPRoute 구조와 Ingress 대비 무엇이 나아졌는지
  (역할 분리: 인프라팀은 Gateway, 앱팀은 Route)
- Helm으로 컨트롤러 설치 → Gateway API로 ALB 자동 생성
- Ingress는 **비교·마이그레이션 관점으로만** 다룹니다
- `targetType: ip` — ALB가 파드 IP로 직접 라우팅 (Day 6 VPC CNI의 이점)
- 컨트롤러는 트래픽 경로에 없다 (설정 흐름 vs 트래픽 흐름 분리)
- ⚠️ ALB는 Terraform state 밖 — **정리 순서가 중요**
- 📄 상세: [day-08-gateway-api.md](day-08-gateway-api.md)

> **Phase 1 완료** — 앱 배포 → 애드온 이해 → 파드 권한 → 인터넷 노출까지 마쳤습니다.

---

## Phase 2 — 운영 심화

### Day 9 — 스토리지 (EBS CSI) ✅
파드가 죽어도 데이터가 살아남게 합니다.
- PersistentVolume / PVC / StorageClass — `provisioner`는 이름표일 뿐, 드라이버는 따로 설치
- EKS 기본 `gp2`(in-tree, immutable) 대신 CSI 기반 `gp3` StorageClass를 기본값으로
- `volumeBindingMode` — `WaitForFirstConsumer`로 AZ 불일치 방지 (EBS는 AZ에 묶임)
- 드라이버 = controller(AWS 원격 작업) + node(노드 로컬 마운트). CNI(바이너리)와 CSI(gRPC 서비스)의 차이
- 관리형 애드온 안에서 Pod Identity를 바로 연결 (Day 8의 별도 association과 대비)
- 실습에서 발견: RWO는 **노드** 단위 / Recreate는 롤아웃에만 / SIGTERM 처리의 효과
- `make destroy`에 PVC 정리 단계 추가 (EBS도 Terraform state 밖)
- 📄 상세: [day-09-storage.md](day-09-storage.md)

### Day 10 — 오토스케일링 ✅
부하에 따라 파드와 노드가 스스로 늘고 줄게 합니다.
- **HPA는 파드, Cluster Autoscaler는 노드** — 둘은 직접 대화하지 않고 **Pending 파드**로만 이어진다
- metrics-server(애드온)가 HPA의 전제. 사용률은 노드가 아니라 **파드 requests 대비**
- CA는 CPU가 아니라 **스케줄 실패**를 보고, requests 기준으로 시뮬레이션한다
- ASG 태그로 자동 탐색 + 같은 태그로 IAM 권한 제한 (Pod Identity, 정책 직접 작성)
- Terraform과 `desired_size` 충돌 → `ignore_changes` (min/max는 Terraform, desired는 CA)
- 실습: Pending → 약 45초 만에 노드 추가 / 축소는 emptyDir 파드 때문에 **새 노드만**
- 실습에서 발견: 롤링 업데이트는 옛 파드도 세서 분산이 틀어진다 (`matchLabelKeys`)
- Karpenter는 심화 주제로 미룸
- 📄 상세: [day-10-autoscaling.md](day-10-autoscaling.md)

### Day 11 — 관측성 (Observability) ✅
클러스터에서 일어난 일을 클러스터 밖(CloudWatch)에 기록으로 남깁니다.
- 컨트롤플레인 로그 5종 (`enabled_cluster_log_types`) — Day 2에서 비용 때문에 꺼둔 것
- Container Insights 애드온 = CloudWatch Agent(메트릭) + Fluent Bit(로그), Pod Identity
- **로그 그룹을 Terraform으로 먼저 생성** — 안 그러면 무기한 보관 + state 밖 고아
- 애드온 기본값 정리 (Application Signals 자동 주입, node-exporter requests 끄기)
- 실습: 사라진 노드의 로그가 남음 / audit로 HPA·CA·node-controller 신원과 순서 재구성
- 발견: 관측 도구도 requests를 먹는다 / `@timestamp`는 전달 시각일 수 있다
- Prometheus/Grafana는 심화 주제로 미룸 (CloudWatch와의 역할 분담은 노트에 정리)
- 📄 상세: [day-11-observability.md](day-11-observability.md)

### Day 12 — 리팩터링: 모듈화 & 환경 분리 ✅
Day 1~11에 펼쳐놓은 코드를 모듈로 묶고 dev/prod를 분리합니다.
- 모듈 = 디렉터리. 입력은 `variables.tf`, 출력은 `outputs.tf`, 안의 리소스는 밖에서 못 봄
- 경계: network → cluster → platform (한 방향). **모듈 경계가 순환 참조를 드러냄**
  → Day 11 컨트롤플레인 로그 그룹을 cluster 모듈로 이동
- 반복 4회를 겪은 뒤 뽑은 재사용 모듈 `pod-identity-role` (관리형/인라인 정책, 연결 on/off)
- `for_each`에 list를 쓰면 apply 전 미정 값으로 plan 실패 → map으로 해결
- 환경 분리는 **디렉터리 + 백엔드 key**. workspace와의 비교표
- 검증: 리팩터링 전후 `Plan: 54 to add`로 동일함을 워크트리로 확인
- 살아 있는 리소스였다면 `moved` 블록 / `terraform state mv`가 필요 (오늘은 state가 비어 불필요)
- 📄 상세: [day-12-modules.md](day-12-modules.md)
- ~~S3 원격 백엔드로 state 관리~~ → ✅ **선행 완료**: [remote-state.md](remote-state.md)
  (맥북 여러 대에서 작업하게 되어 앞당겨 적용했습니다)

> **커리큘럼 12일 완료** — 이후는 아래 심화 주제에서 골라 이어갑니다.

---

## 이후 심화 주제 (선택)

- GitOps (ArgoCD/Flux) — Day 5의 Helm 차트를 ArgoCD로 배포
- 네트워크 정책 / 보안 (Network Policy, Pod Security Standards)
- 서비스 메시 개요
- Karpenter — Day 10 Cluster Autoscaler와 비교 (ASG 없이 인스턴스를 직접 생성)
- Prometheus / Grafana — Day 11 CloudWatch와 비교 (클러스터 안 메트릭은 Prometheus, AWS 리소스는 CloudWatch)
- 비용 최적화 (Spot, 우측 사이징)
  - ~~Graviton~~ → ✅ **선행 적용**: Day 3 노드를 t4g.medium(arm64)으로 전환.
    맥북과 아키텍처가 일치해 빌드가 단순해지고 20% 저렴합니다
- 업그레이드 전략 (클러스터/노드 버전 업, 표준 지원 → 연장 지원 요금 급등 주의)

---

## 진행 팁

- 각 Day 끝에 **꼭 `terraform destroy`** — 비용의 대부분(EKS 컨트롤플레인, NAT)이 시간당 과금입니다.
- `terraform plan`을 apply 전에 항상 읽어보세요. "무엇이 왜 만들어지는지" 이해가 핵심입니다.
- 막히면 그날의 `docs/day-XX-*.md` 노트를 참고하세요.
