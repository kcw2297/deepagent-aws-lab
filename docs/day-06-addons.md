# Day 6 — 핵심 애드온 (VPC CNI · kube-proxy · CoreDNS)

> 목표: Day 5에서 본 `podIP: 10.0.61.87`이 **어떻게 가능한지** 이해하고,
> 애드온을 Terraform 관리로 편입한다.
>
> 일반 쿠버네티스 개념(Service, DNS, DaemonSet)은 아는 것으로 보고
> **EKS 고유의 문제**에 집중합니다.

## CNI 선택: AWS VPC CNI로 확정

이 리포는 **AWS VPC CNI**를 씁니다. EKS 기본값이고, 파드가 진짜 VPC IP를 받는
구조가 AWS 서비스들과의 통합(파드 단위 보안그룹, ALB `target-type: ip`,
VPC Flow Logs)의 전제가 됩니다.

## 흔한 오해 세 가지

### ① "애드온은 컨트롤플레인의 구성이다" → ❌

전부 **내 워커 노드에서 도는 일반 파드**입니다.

```
aws-node-25lw9      NODE: ip-10-0-50-225   ← 내 EC2
coredns-...-6w77q   NODE: ip-10-0-50-225   ← 내 EC2
kube-proxy-qpcbq    NODE: ip-10-0-42-154   ← 내 EC2
```

진짜 컨트롤플레인은 목록에 아예 없습니다.

```bash
kubectl get pods -A | grep -E 'kube-apiserver|etcd|kube-scheduler|kube-controller-manager'
# → 없음
```

직접 설치한 쿠버네티스라면 이 4개가 마스터 노드의 static pod로 보입니다.
EKS에서는 AWS 계정 영역에 있어 보이지 않습니다 — Day 2에서 "내 EC2가 0개인데
클러스터는 ACTIVE"를 확인했던 그 구조입니다.

```
AWS 영역 (안 보임)              내 노드 (보임)
├─ kube-apiserver              ├─ aws-node    (DaemonSet)
├─ etcd                        ├─ kube-proxy  (DaemonSet)
├─ kube-scheduler              └─ coredns     (Deployment)
└─ kube-controller-manager
   컨트롤플레인 ($0.10/h)          애드온 (내 노드 자원 소모)
```

구분 기준:
- **컨트롤플레인** = 클러스터에 하나(다중화). **결정**을 내림
- **노드 컴포넌트** = 노드마다 하나씩 필요. **실행**함 → `kubelet`, `kube-proxy`, CNI

`kube-proxy`는 각 노드의 iptables를 고쳐야 하니 노드에 있어야만 합니다. 그래서 DaemonSet입니다.

### ② "add-on으로 등록해야 설치된다" → ❌

**클러스터 생성 시 EKS가 자동으로 깔아줍니다.** 등록 없이도 정상 동작하며,
실제로 Day 5까지 등록 없이 앱 배포까지 다 됐습니다.

`aws_eks_addon`은 새로 설치하는 게 아니라 **이미 도는 것을 인수**합니다.
그래서 `resolve_conflicts_on_create = "OVERWRITE"`가 필요합니다 —
없으면 "이미 존재한다"며 실패합니다.

### ③ "버전만 같으면 편입해도 아무 일 없다" → ❌ (직접 겪음)

지금 도는 버전과 **똑같은 값**을 지정했는데도 `aws-node`는 재시작됐습니다.

| 애드온 | generation | 재시작 |
|--------|-----------|--------|
| `vpc-cni` | 1 → **2** | ✅ 됨 |
| `kube-proxy` | 1 | ❌ 안 됨 |
| `coredns` | 1 | ❌ 안 됨 |

이유는 레이블에 있습니다.

```
aws-node   : app.kubernetes.io/managed-by = Helm
             helm.sh/chart = aws-vpc-cni-1.22.4     ← 관리형 버전이 Helm 차트 기반
kube-proxy : eks.amazonaws.com/component = kube-proxy ← 기존과 동일
```

**버전이 같아도 매니페스트 내용이 다르면 롤링 교체가 일어납니다.**
이미 IP를 받은 파드는 영향 없었지만(앱 파드 IP·생성시각 그대로),
CNI가 재시작되는 몇 초 동안은 새 파드에 IP를 줄 수 없습니다.
**운영 환경이라면 트래픽이 적은 시간대에** 하세요.

## 핵심 1 — VPC CNI: 파드 IP의 정체

노드 하나를 뜯어보면:

```
노드 i-04b81dd4209c6e6f9 (t4g.medium)
├── eni-01fdb62d50d883697   IP 6개   (주 IP 10.0.42.154)
└── eni-07d35e6a5ce84825c   IP 6개   (주 IP 10.0.36.81)
```

| 파드 | IP | 정체 |
|------|-----|------|
| 앱 파드 | `10.0.42.61` | ENI의 **보조 IP** |
| `aws-node` | `10.0.42.154` | 노드 IP (hostNetwork) |
| `kube-proxy` | `10.0.42.154` | 노드 IP (hostNetwork) |

**CNI가 ENI에 IP를 미리 쌓아두고, 파드가 뜨면 그중 하나를 veth에 꽂아줍니다.**
오버레이가 아니라 진짜 VPC IP라서 VPC 안 어디서나 직접 통신됩니다.

### 따라오는 제약: 최대 파드 수

```
(ENI 수 × (ENI당 IP − 1)) + 2
t4g.medium = 3 × (6 − 1) + 2 = 17개
                        ▲      ▲
             각 ENI의 주 IP는  hostNetwork 파드
             노드가 쓰므로 −1   (aws-node, kube-proxy)
```

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,MAXPODS:.status.allocatable.pods'
# → 17
```

**CPU·메모리가 남아돌아도 IP가 없으면 파드가 Pending**입니다.
Day 3에서 본 "노드는 한가한데 파드가 안 뜨는" 또 다른 원인입니다.

### ENI 한계는 AWS 플랫폼 제약입니다

리눅스 NIC에는 IP 개수 제한이 사실상 없습니다. **하지만 ENI는 리눅스 NIC가 아닙니다.**

```
t4g.nano    : ENI 2 × IP 2
t4g.medium  : ENI 3 × IP 6
m7g.large   : ENI 3 × IP 10
m7g.4xlarge : ENI 8 × IP 30
```

인스턴스 타입마다 AWS가 정한 하드 제약입니다. 이유는 VPC의 구조에 있습니다 —
VPC는 물리 네트워크 위에 얹은 **소프트웨어 정의 네트워크**이고, 모든 사설 IP가
AWS **매핑 서비스**에 "이 IP는 이 호스트의 이 ENI"로 등록돼 있어야 라우팅됩니다.

```
리눅스 커널에 IP 100개 추가  →  커널은 받아들임
                                  ↓
         AWS 매핑 서비스에 등록 안 됨  →  패킷이 어디로도 안 감 ❌
```

### 완화 수단

| 설정 | 효과 | 현재 |
|------|------|------|
| `ENABLE_PREFIX_DELEGATION` | IP를 `/28` 블록(16개)으로 받아 최대 파드 수 대폭 증가 | `false` |
| `WARM_ENI_TARGET` | IP를 미리 확보 — 기동 속도 ↔ IP 낭비 | `1` |
| `ENABLE_POD_ENI` | 파드 단위 보안그룹 (트렁크/브랜치 ENI) | `false` |
| `AWS_VPC_K8S_CNI_EXTERNALSNAT` | 파드가 인터넷 나갈 때 SNAT 여부 | `false` |

`eks-addons.tf`의 `configuration_values`에 주석으로 남겨뒀습니다.

### 서브넷 IP 고갈

파드마다 VPC IP를 쓰므로 소모가 큽니다. 우리 `/20`(4,096개)은 넉넉하지만,
`/24`(256개)로 시작한 클러스터가 확장하다 IP가 말라 파드를 못 띄우는 사고가 흔합니다.
**Day 1의 CIDR 사이징이 여기서 영향을 미칩니다.**

## 핵심 2 — VPC CNI라서 가능한 것들

| 기능 | 왜 가능한가 |
|------|------------|
| **파드 단위 보안그룹** | 파드가 진짜 ENI/IP를 가지니 SG를 붙일 수 있음 |
| **ALB `target-type: ip`** | LB가 파드 IP로 직접 라우팅 (노드 홉 생략) — Day 8 |
| **VPC Flow Logs** | 파드 트래픽이 로그에 그대로 잡힘 |
| VPC 내 직접 통신 | RDS 등과 오버레이 없이 통신 |

## 핵심 3 — kube-proxy

Service의 ClusterIP는 **어디에도 존재하지 않는 가상 IP**입니다.
kube-proxy가 각 노드의 iptables 규칙을 관리해 실제 파드 IP로 DNAT합니다.

```
KUBE-SERVICES  →  KUBE-SVC-XXXX  →  KUBE-SEP-XXXX  →  파드 IP
   (진입)          (Service별)       (엔드포인트별)
```

파드가 2개면 `KUBE-SEP`도 2개이고 확률로 분기합니다.
Day 5에서 `svc/myapp-deepagent-app`으로 접근됐던 게 이 규칙 덕분입니다.

직접 보려면:

```bash
N=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl debug node/$N -it --profile=sysadmin --image=busybox -- sh
# 파드 안에서:
chroot /host iptables -t nat -L KUBE-SERVICES -n | head -20
```

> 끝나면 디버그 파드를 지우세요: `kubectl get pods | grep node-debugger`

kube-proxy 버전이 쿠버네티스 버전(1.36)과 묶여 있는 점도 눈여겨볼 부분입니다 —
컨트롤플레인과 버전 차이가 크면 안 되기 때문입니다.

## 핵심 4 — CoreDNS가 유일하게 Deployment인 이유

```bash
kubectl get ds,deploy -n kube-system \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled,REPLICAS:.status.replicas'
```

- `aws-node`, `kube-proxy` → 노드 수(2)를 따라감 (**DaemonSet**)
- `coredns` → 고정 2개 (**Deployment**)

**노드가 100대로 늘어도 CoreDNS는 2개 그대로**입니다.
대규모 클러스터에서 DNS가 병목이 되는 게 알려진 문제이고,
그때 replica를 늘리거나 NodeLocal DNSCache를 씁니다.

```bash
kubectl run dnstest --rm -it --restart=Never --image=busybox -- sh
# 파드 안에서:
nslookup myapp-deepagent-app.demo.svc.cluster.local
cat /etc/resolv.conf    # nameserver = CoreDNS의 ClusterIP (kube-dns Service)
```

## 핵심 5 — 자체 관리 vs 관리형 애드온

| | 자체 관리 (등록 전) | 관리형 (등록 후) |
|---|---|---|
| 동작 | ✅ 잘 됨 | ✅ 잘 됨 |
| 버전 확인 | 이미지 태그를 들여다봐야 | `terraform output` / `describe-addon` |
| 업그레이드 | 매니페스트 직접 적용 | 변수 바꾸고 `make apply` |
| 호환성 검증 | 내 책임 | AWS가 k8s 버전과 검증 |
| 설정 변경 | DaemonSet env 직접 수정 | `configuration_values` |
| 상태 보고 | 없음 | `status: ACTIVE / DEGRADED` |

**등록하는 이유는 "버전을 코드로 관리하기 위해"** 입니다.
`versions.tf`에서 Terraform·provider 버전을 고정한 것과 같은 사고방식입니다.

## 오늘 만든 것

`terraform/eks-addons.tf` — `aws_eks_addon` 3개 (**비용 $0**)

```hcl
aws_eks_addon.vpc_cni      # v1.22.4-eksbuild.3
aws_eks_addon.kube_proxy   # v1.36.0-eksbuild.17
aws_eks_addon.coredns      # v1.14.3-eksbuild.14   (depends_on 노드 그룹)
```

버전은 `terraform.tfvars`에 명시했습니다. 사용 가능한 버전 확인:

```bash
aws eks describe-addon-versions --addon-name vpc-cni --kubernetes-version 1.36 \
  --query "addons[0].addonVersions[:5].{Version:addonVersion,Default:compatibilities[0].defaultVersion}" --output table
```

CoreDNS에만 `depends_on = [aws_eks_node_group.this]`를 걸었습니다 —
일반 파드라 노드가 없으면 스케줄될 수 없기 때문입니다.
(DaemonSet인 둘은 노드가 생기면 자동으로 붙습니다)

## 관찰 포인트

1. 최대 파드 수가 17인 이유를 공식으로 설명할 수 있나요?
2. `--replicas=40`으로 올리면 무엇이 먼저 고갈되나요? (힌트: CPU가 아님)
3. `aws-node`와 앱 파드의 IP가 다른 이유는? (hostNetwork)
4. CoreDNS가 DaemonSet이 아니어서 생기는 문제는?
5. 애드온을 등록하지 않아도 클러스터가 동작하는데, 등록하는 이유는?

## 비용 메모

- **오늘 추가 비용 $0** — 이미 도는 파드를 관리 대상으로 옮긴 것뿐입니다
- 다만 애드온은 **내 노드 자원**을 씁니다 (최대 파드 17개 중 2개를 hostNetwork로 차지)
- 시간당 합계는 그대로 **≈ $0.24**

## 다음 (Day 7)

파드에 AWS 권한을 **파드 단위로** 주는 방법입니다.
일반 파드는 기본적으로 AWS 자격증명이 **아예 없습니다**
(IMDS 홉 제한 1에 막힘 — Day 7에서 확인). IRSA/Pod Identity로 해결합니다.
Day 5에서 본 ServiceAccount 토큰의 발급자
(`https://oidc.eks.ap-northeast-2.amazonaws.com/id/...`)가 그 열쇠입니다.
