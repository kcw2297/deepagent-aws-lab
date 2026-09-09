# ============================================================================
# Day 6 — 핵심 애드온
#
# 클러스터를 만들면 EKS가 3개를 자동으로 깔아줍니다.
#   aws-node(VPC CNI) · kube-proxy · CoreDNS
# 그런데 `aws eks list-addons`는 비어 있습니다. "설치는 됐지만 관리 대상은 아닌"
# 자체 관리(self-managed) 상태이기 때문입니다.
#
# [왜 관리형 애드온으로 편입하는가]
#   자체 관리  → 버전이 클러스터 생성 시점에 고정. 업그레이드는 내가 매니페스트로.
#   관리형     → 버전을 코드에 명시. AWS가 호환성 검증. terraform apply로 업그레이드.
#
# [실제로 겪은 것] 지금 도는 버전과 같은 값을 지정했는데도 aws-node는 재시작됐습니다.
# 관리형 vpc-cni는 Helm 차트 기반이라 레이블/애노테이션이 달라져 DaemonSet이
# 갱신(generation 1→2)되고 파드가 롤링 교체됩니다.
# kube-proxy와 CoreDNS는 매니페스트가 동일해 그대로였습니다.
# 이미 IP를 받은 파드는 영향이 없지만, CNI가 재시작되는 몇 초 동안은
# 새 파드에 IP를 줄 수 없으므로 운영 환경이라면 트래픽이 적은 시간대에 하세요.
#
# 💰 애드온 자체는 무료입니다. 이미 도는 파드를 관리 대상으로 옮기는 것뿐입니다.
# ============================================================================

# ----------------------------------------------------------------------------
# 1) VPC CNI (aws-node) — 파드에게 VPC IP를 주는 주인공
#
# [파드가 IP를 받는 원리]
# 노드에 ENI를 붙이고, 각 ENI의 "보조 IP"를 파드의 veth에 꽂아줍니다.
# 그래서 파드 IP가 10.0.x.x — 오버레이가 아니라 진짜 VPC IP입니다.
#
# [따라오는 제약: 최대 파드 수]
#   (ENI 수 × (ENI당 IP − 1)) + 2
#   t4g.medium = 3 × (6 − 1) + 2 = 17개
#   각 ENI의 주 IP는 노드가 쓰므로 −1, hostNetwork 파드(aws-node/kube-proxy)가 +2.
# CPU·메모리가 남아돌아도 IP가 없으면 파드가 Pending에 걸립니다.
# ENI 수와 ENI당 IP 수는 인스턴스 타입마다 AWS가 정한 하드 제약입니다
# (t4g.nano 2×2, t4g.medium 3×6, m7g.4xlarge 8×30).
# ----------------------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = var.addon_version_vpc_cni

  # 이미 자체 관리로 설치돼 있으므로 덮어쓰며 인수합니다.
  # 이게 없으면 "이미 존재한다"며 실패합니다.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # [학습 노트] 여기서 CNI 동작을 조절할 수 있습니다. 지금은 기본값을 씁니다.
  #
  # configuration_values = jsonencode({
  #   env = {
  #     # 접두사 위임: IP를 하나씩이 아니라 /28 블록(16개)으로 받습니다.
  #     # 최대 파드 수가 크게 늘어나 IP 제약을 완화합니다.
  #     ENABLE_PREFIX_DELEGATION = "true"
  #     # 워밍풀: 파드가 뜰 때마다 AWS API로 IP를 받으면 느리므로 미리 확보해 둡니다.
  #     # 기동 속도 ↔ IP 낭비의 트레이드오프입니다.
  #     WARM_ENI_TARGET = "1"
  #   }
  # })

  tags = {
    Name = "${var.project}-vpc-cni"
  }
}

# ----------------------------------------------------------------------------
# 2) kube-proxy — Service의 ClusterIP를 실제 파드 IP로 바꿔주는 역할
#
# Service의 ClusterIP는 어디에도 존재하지 않는 가상 IP입니다.
# kube-proxy가 각 노드의 iptables 규칙(KUBE-SERVICES → KUBE-SVC-* → KUBE-SEP-*)을
# 관리해서, 그 IP로 가는 패킷을 실제 파드 IP로 DNAT합니다.
# Day 5에서 svc/myapp-deepagent-app 으로 접근됐던 게 이 규칙 덕분입니다.
#
# 버전이 쿠버네티스 버전(1.36)과 묶여 있는 점에 주목하세요.
# 컨트롤플레인과 버전 차이가 크면 안 되기 때문입니다.
# ----------------------------------------------------------------------------
resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  addon_version = var.addon_version_kube_proxy

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${var.project}-kube-proxy"
  }
}

# ----------------------------------------------------------------------------
# 3) CoreDNS — 클러스터 내부 DNS (서비스 디스커버리)
#
# `myapp-deepagent-app.demo.svc.cluster.local` 같은 이름을 ClusterIP로 바꿔줍니다.
#
# [주목: 셋 중 유일하게 DaemonSet이 아니라 Deployment입니다]
#   aws-node, kube-proxy → 모든 노드에 하나씩 필요 (DaemonSet)
#   CoreDNS              → 몇 개만 있으면 됨 (Deployment, 기본 2개)
# 노드가 100대로 늘어도 CoreDNS는 2개 그대로라, 대규모 클러스터에서
# DNS가 병목이 되는 게 알려진 문제입니다. (그때 replica를 늘리거나
# NodeLocal DNSCache를 씁니다)
#
# CoreDNS 파드는 일반 파드라 노드가 있어야 스케줄됩니다.
# 그래서 노드 그룹이 준비된 뒤에 다루도록 순서를 강제합니다.
# ----------------------------------------------------------------------------
resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  addon_version = var.addon_version_coredns

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]

  tags = {
    Name = "${var.project}-coredns"
  }
}
