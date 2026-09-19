# ============================================================================
# Day 9 — 스토리지 (EBS CSI 드라이버)
#
# [왜 필요한가]
# 파드는 언제든 죽고 다른 노드에서 다시 뜹니다. 컨테이너 안에 쓴 데이터는
# 함께 사라집니다. 데이터를 살리려면 파드 밖에 디스크를 두고 붙여야 합니다.
# 그 디스크가 EBS이고, 쿠버네티스가 EBS를 다루게 해주는 게 CSI 드라이버입니다.
#
# [드라이버의 두 부분]
#   ebs-csi-controller (Deployment) : AWS API로 볼륨 생성·부착·삭제  ← AWS 권한 필요
#   ebs-csi-node       (DaemonSet)  : 각 노드에서 부착된 디스크를 포맷·마운트 ← AWS 권한 불필요
# 부착은 원격 작업(어디서든 AWS API 호출), 마운트는 로컬 작업(그 노드 안에서만)이라
# 주체가 나뉩니다.
#
# [CNI와의 차이]
# CNI(Day 6)는 aws-node가 /opt/cni/bin 에 바이너리를 복사해두고 kubelet이 exec합니다.
# CSI는 바이너리를 두지 않고, ebs-csi-node가 상주하며 Unix 소켓으로 gRPC 요청을 받습니다.
#
# [StorageClass와의 관계]
# k8s/day09/storageclass.yaml 의 provisioner: ebs.csi.aws.com 은 이름표일 뿐입니다.
# 이 애드온이 설치돼 드라이버가 그 이름으로 자기 등록을 해야 StorageClass가 동작합니다.
# (StorageClass를 먼저 만들어도 드라이버는 생기지 않습니다 — 방향이 반대)
#
# 💰 드라이버 자체는 무료. PVC로 생성되는 EBS 볼륨이 GB-월 단위로 과금됩니다.
# ============================================================================

# ----------------------------------------------------------------------------
# 1) 컨트롤러용 IAM 역할 — Pod Identity 방식 (Day 7·8과 같은 패턴)
#
# 권한이 필요한 건 controller뿐입니다. node 플러그인은 AWS를 부르지 않습니다.
# ----------------------------------------------------------------------------
resource "aws_iam_role" "ebs_csi" {
  name = "${var.project}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = {
    Name = "${var.project}-ebs-csi-role"
  }
}

# AWS 관리형 정책. ec2:CreateVolume, AttachVolume, DeleteVolume, CreateSnapshot 등.
# Day 8 LB Controller는 공식 정책 파일을 내려받아 썼지만, EBS CSI는 AWS가
# 관리형 정책으로 제공하므로 ARN만 붙이면 됩니다.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ----------------------------------------------------------------------------
# 2) EBS CSI 드라이버 — 관리형 애드온
#
# [Day 8과 다른 점: Pod Identity 연결을 애드온 안에서 바로]
# Day 8의 LB Controller는 Helm으로 설치했기 때문에
#   aws_eks_pod_identity_association 을 별도 리소스로 만들었습니다.
# EBS CSI는 관리형 애드온이라 애드온 리소스 안에 연결을 같이 선언할 수 있습니다.
# 애드온이 만드는 SA 이름을 우리가 알 필요 없이, 애드온과 권한이 한 곳에 묶입니다.
# ----------------------------------------------------------------------------
resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = var.addon_version_ebs_csi

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa" # 애드온이 kube-system에 만드는 SA
  }

  # controller 파드가 노드에 스케줄돼야 하고, Pod Identity 에이전트가 있어야
  # 자격증명을 받을 수 있습니다. 정책도 먼저 붙어 있어야 합니다.
  depends_on = [
    aws_eks_node_group.this,
    aws_eks_addon.pod_identity,
    aws_iam_role_policy_attachment.ebs_csi,
  ]

  tags = {
    Name = "${var.project}-ebs-csi"
  }
}
