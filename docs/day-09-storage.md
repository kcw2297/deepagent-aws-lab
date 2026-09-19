# Day 9 — 스토리지 (EBS CSI)

> 목표: **파드가 죽어도 데이터가 살아남게** 한다.
> 파드는 언제든 죽고 다른 노드에서 다시 뜹니다. 컨테이너 안에 쓴 데이터는 함께 사라집니다.
> 데이터를 살리려면 파드 밖에 디스크를 두고 붙여야 합니다.

## 오늘의 구조

```
[쿠버네티스]                                [AWS]
  StorageClass gp3                            
    provisioner: ebs.csi.aws.com  ← 이름표     
        ↑                                    
  PVC data-pvc (1Gi, RWO)                    
        ↓ 바인딩                              
  PV pvc-2b97fe60-...  ─────────────────────►  EBS vol-07bcee... (1GB, gp3, 2c)
        ↑                                           ↑ 부착
  파드 writer (2c 노드) ──────────────────────  EC2 노드 (2c)

  [드라이버 — 애드온으로 설치]
  ebs-csi-controller (Deployment ×2) → AWS API로 생성·부착·삭제
  ebs-csi-node       (DaemonSet)     → 노드에서 포맷·마운트
```

## 핵심 개념

### 1. StorageClass의 provisioner는 **이름표**다

```yaml
provisioner: ebs.csi.aws.com
```

이건 "이 이름으로 등록된 드라이버를 찾아라"는 포인터입니다.
**이 필드를 적는다고 드라이버가 설치되지 않습니다.** 직접 확인했습니다.

```
gp3 StorageClass 생성 후 몇 분 뒤:
  ebs-csi 파드            → 없음
  kubectl get csidriver ebs.csi.aws.com → NotFound
  EBS CSI 애드온          → 없음

애드온 설치 후:
  kubectl get csidriver ebs.csi.aws.com
  → ebs.csi.aws.com   ATTACHREQUIRED=true   ✅ 드라이버가 스스로 등록
```

**방향이 반대입니다.**

```
❌ 오해: StorageClass 작성 → AWS가 이름을 보고 → 드라이버 생성
✅ 실제: 애드온 설치 → 드라이버가 "나는 ebs.csi.aws.com" 등록 → StorageClass가 참조
```

Day 8과 정확히 같은 구조입니다.

| | 이름표 (선언) | 실체 (설치) |
|---|---|---|
| Day 8 | `GatewayClass.controllerName: gateway.k8s.aws/alb` | LB Controller (Helm) |
| **Day 9** | `StorageClass.provisioner: ebs.csi.aws.com` | EBS CSI 드라이버 (애드온) |

### 2. EKS 기본 gp2는 옛 방식이라 새로 만들었다

EKS가 클러스터 생성 시 만들어두는 StorageClass:

```
NAME   PROVISIONER             VOLUMEBINDINGMODE
gp2    kubernetes.io/aws-ebs   WaitForFirstConsumer
```

`kubernetes.io/aws-ebs`는 **in-tree**(쿠버네티스 내장) 드라이버로, 쿠버네티스에서 제거되고
CSI로 이전됐습니다. 그리고 **provisioner 필드는 수정할 수 없습니다**:

```
kubectl patch storageclass gp2 -p '{"provisioner":"ebs.csi.aws.com"}'
→ provisioner: Invalid value: "ebs.csi.aws.com": field is immutable
```

그래서 `gp3`를 새로 만들고 기본값으로 지정했습니다 (`k8s/day09/storageclass.yaml`).

| | gp2 (EKS 기본) | **gp3 (신규)** |
|---|---|---|
| 프로비저너 | in-tree (제거됨) | **CSI** |
| 디스크 타입 | gp2 — IOPS가 크기에 비례 | **gp3** — 더 저렴, 기본 3000 IOPS |
| 암호화 | 없음 | **`encrypted: "true"`** |
| 용량 확장 | 불가 | **가능** |
| 기본값 | 아님 (기본값 자체가 없었음) | **✅** |

### 3. `volumeBindingMode` — 두 가지뿐

| | **`Immediate`** | **`WaitForFirstConsumer`** |
|---|---|---|
| 볼륨 생성 시점 | PVC를 만드는 즉시 | **그 PVC를 쓰는 파드가 스케줄될 때** |
| AZ를 누가 정하나 | 볼륨이 먼저 → 파드가 따라감 | **파드가 먼저 → 볼륨이 따라감** |
| 적합 | AZ 제약 없는 스토리지 (EFS) | **AZ에 묶인 스토리지 (EBS)** |

`Immediate`의 문제:

```
① PVC 생성 → 즉시 2a에 EBS 생성
② 볼륨이 2a에 묶여 파드도 2a 노드로만 갈 수 있음
③ 2a 노드가 가득 차면? 2c는 여유가 있어도 못 감 → Pending
```

볼륨이 파드의 요구사항을 모른 채 AZ를 먼저 정해버립니다.

#### 실제 흐름 — 파드는 볼륨보다 먼저 뜨지 않는다

```
① 파드 생성 (PVC 참조)
② 스케줄러가 노드 선택 → PVC에 "선택된 노드" 표시   ← 여기까지가 "기다림"
③ csi-provisioner가 표시를 보고 → CreateVolume (그 노드의 AZ에)
④ csi-attacher → AttachVolume (EC2에 부착)
⑤ kubelet → ebs-csi-node → 포맷 + 마운트
⑥ 이제야 컨테이너 시작
```

파드는 ②에서 노드에 **배정**되지만, ③~⑤ 동안 `ContainerCreating`으로 기다립니다.
**배정과 실행이 다릅니다.**

실제 결과:
```
파드가 뜬 노드   : ip-10-0-56-14  (ap-northeast-2c)
볼륨의 AZ        : ap-northeast-2c
PV가 요구하는 AZ : ap-northeast-2c        ← 세 값 일치
```

### 4. 드라이버는 두 부분이다

| | **ebs-csi-controller** | **ebs-csi-node** |
|---|---|---|
| 형태 | Deployment (2개) | **DaemonSet (노드마다)** |
| 하는 일 | 볼륨 **생성·부착·삭제** | 볼륨 **포맷·마운트** |
| 작업 대상 | **AWS** (원격) | **노드 OS** (로컬) |
| AWS API | ✅ | ❌ |
| 필요 권한 | IAM (Pod Identity) | 노드 root (privileged) |

**부착은 원격 작업(어디서든 AWS API 호출), 마운트는 로컬 작업(그 노드 안에서만)** 이라
주체가 나뉩니다. Day 6의 CoreDNS(Deployment)와 aws-node(DaemonSet) 관계와 같습니다.

#### controller 파드 안에는 컨테이너가 6개

```
ebs-plugin        ← 드라이버 본체. 실제로 AWS를 부름
csi-provisioner   ← PVC를 watch → 볼륨 생성 요청
csi-attacher      ← 볼륨 부착 요청
csi-snapshotter   ← 스냅샷
csi-resizer       ← 용량 확장
liveness-probe    ← 상태 확인
```

"controller가 PVC를 watch한다"의 실체가 `csi-provisioner`입니다.
watch는 **주기적 폴링이 아니라 이벤트 기반**입니다 (Day 8 LB Controller와 같은 방식).

Pod Identity는 **파드의 모든 컨테이너**에 환경변수를 주입해서 `AWS_CONTAINER_*`가 6쌍 보입니다.
node 파드에는 없습니다 — AWS를 부르지 않으니까요.

#### 덤: `ebs-csi-node-windows` 0/0

애드온이 윈도우 노드용 DaemonSet도 함께 설치합니다.
`nodeSelector: kubernetes.io/os=windows`에 맞는 노드가 없어 파드가 0개입니다.

### 5. CNI는 바이너리, CSI는 서비스

Day 6의 VPC CNI와 인터페이스 방식이 다릅니다. 노드 안을 직접 확인했습니다.

```
노드의 /opt/cni/bin/
  aws-cni          14 MB   -rwxr-xr-x   ← 실행 파일
  bridge, host-local, loopback, portmap, ...

노드의 /etc/cni/net.d/
  10-aws.conflist          ← "aws-cni를 써라"
```

| | **CNI** | **CSI** |
|---|---|---|
| 인터페이스 | **실행 파일 exec** (stdin/stdout JSON) | **gRPC** (Unix 소켓) |
| 노드에 바이너리 | ✅ `/opt/cni/bin/` | ❌ 없음 |
| 프로세스 수명 | 호출마다 실행·종료 | **상주** |
| 설치 수단 | DaemonSet이 바이너리를 호스트에 복사 | DaemonSet + Deployment 자체가 드라이버 |

VPC CNI의 `aws-node` DaemonSet은 initContainer(`aws-vpc-cni-init`)가
hostPath로 `/opt/cni/bin`에 바이너리를 복사합니다. **파드가 노드에 실행 파일을 설치하는 구조**입니다.

> 왜 다를까: CNI(2016)는 컨테이너 런타임 공용 규격이라 가장 단순한 형태를 택했습니다.
> CSI(2018~)는 생성·부착·스냅샷·확장 같은 상태 있는 긴 작업이 많아 상주 서비스가 맞았습니다.

### 6. 애드온 설치는 AWS가 매니페스트를 적용하는 것

```hcl
resource "aws_eks_addon" "ebs_csi" {
  addon_name    = "aws-ebs-csi-driver"
  addon_version = "v1.66.0-eksbuild.1"
}
```

Terraform은 **"이 애드온, 이 버전"만** 말합니다. controller·node의 매니페스트는
**AWS가 보유**하고 있고, EKS가 그걸 클러스터 API 서버에 적용합니다. 그 뒤 스케줄러가
파드를 노드에 배치합니다. **AWS가 노드를 직접 만지지 않습니다.**

그래서 controller가 2개인 것, 컨테이너가 6개인 것은 우리가 정한 게 아니라 AWS의 기본값입니다.

#### Pod Identity를 애드온 안에서 바로 연결

Day 8과 다른 점입니다.

```hcl
resource "aws_eks_addon" "ebs_csi" {
  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }
}
```

Day 8의 LB Controller는 Helm으로 설치해서 `aws_eks_pod_identity_association`을 별도로 만들었습니다.
관리형 애드온은 **설치와 권한이 한 리소스에 묶입니다.**

### 7. 자격증명은 컨테이너에 저장되지 않는다

controller의 실제 환경변수:

```
AWS_CONTAINER_CREDENTIALS_FULL_URI     = http://169.254.170.23/v1/credentials
AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = /var/run/secrets/pods.eks.amazonaws.com/.../eks-pod-identity-token
```

| 환경변수 | 가리키는 것 | 자격증명인가 |
|---|---|---|
| `..._FULL_URI` | **에이전트 주소** (`.170.23`) | ❌ "여기에 물어봐라" |
| `..._TOKEN_FILE` | 신분 증명 토큰 (`aud: pods.eks.amazonaws.com`) | ❌ "나는 이 SA다" |

순서:
```
① 파드 생성 시 EKS 웹훅이 환경변수 2개와 토큰 볼륨 주입   ← 자격증명은 아직 없음
② SDK가 필요할 때 토큰을 들고 에이전트(.170.23)에 요청
③ 에이전트(hostNetwork) → IMDS(.169.254)에서 노드 역할 → eks-auth:AssumeRoleForPodIdentity
④ SDK가 받은 자격증명을 **메모리에만** 보관, 만료되면 ②부터
```

**파드는 IMDS를 부르지 않습니다** (Day 7). 자격증명은 파일에도 환경변수에도 쓰이지 않습니다.

#### 스펙에 `AWS_ACCESS_KEY_ID`가 보이는 이유

```
AWS_ACCESS_KEY_ID     ← secretKeyRef: aws-secret / key_id      optional: true
AWS_SECRET_ACCESS_KEY ← secretKeyRef: aws-secret / access_key  optional: true
```

EBS CSI는 Pod Identity·IRSA를 못 쓰는 환경을 위해 `aws-secret`에 정적 키를 넣는
**대체 경로**를 열어둡니다. 우리 클러스터엔 그 Secret이 없고(`NotFound`) `optional: true`라
**실행 시 설정되지 않습니다.** 영구 키를 쓰지 않는 방향이 맞습니다.

### 8. EBS CSI는 블록 디스크 전용이다

| | EBS CSI | RDS (DB) | ElastiCache (캐시) |
|---|---|---|---|
| 정체 | **블록 디스크** | 관리형 DB 서비스 | 관리형 캐시 서비스 |
| 쿠버네티스와의 관계 | PV로 **마운트** | 앱이 **네트워크로 접속** | 앱이 **네트워크로 접속** |
| CSI 필요 | ✅ | ❌ | ❌ |

쿠버네티스 안에서 DB를 직접 돌리면(StatefulSet) 그 데이터 디스크로 EBS를 쓰게 되지만,
드라이버 자체는 디스크만 압니다.

## 오늘 만든 것

**Terraform** — `terraform/eks-storage.tf` (3개)

```
aws_iam_role.ebs_csi                  pods.eks.amazonaws.com 신뢰
aws_iam_role_policy_attachment        AmazonEBSCSIDriverPolicy (AWS 관리형)
aws_eks_addon.ebs_csi                 드라이버 + Pod Identity 연결
```

**쿠버네티스** — `k8s/day09/`

```
storageclass.yaml   gp3, CSI, WaitForFirstConsumer, 암호화, 기본값
pvc-test.yaml       PVC 1Gi + 5초마다 시각을 쓰는 파드
```

**Makefile** — `make destroy`에 PVC 정리 단계 추가 (아래 참고)

## 실습 순서

```bash
make plan     # "Plan: 3 to add"
make apply    # 애드온 1~2분

# 드라이버가 떴는지
kubectl get deploy,ds -n kube-system | grep ebs-csi
kubectl get csidriver ebs.csi.aws.com

# StorageClass + PVC
kubectl apply -f k8s/day09/storageclass.yaml
kubectl create namespace demo
kubectl apply -f k8s/day09/pvc-test.yaml
kubectl get pvc -n demo

# AWS에 실제 EBS가 생겼는지 (태그로 PVC 볼륨만 골라냄)
aws ec2 describe-volumes --region ap-northeast-2 \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=data-pvc" \
  --query "Volumes[].{Id:VolumeId,AZ:AvailabilityZone,Size:Size,Type:VolumeType,Encrypted:Encrypted}" --output table

# 데이터 영속성
kubectl exec -n demo deploy/writer -- tail -3 /data/log.txt
kubectl delete pod -n demo -l app=writer
kubectl exec -n demo deploy/writer -- cat /data/log.txt
```

## 실습 결과

### 데이터가 살아남았다

```
=== 파드 시작: writer-6b4dcfbc97-cvx2f ===   ← 첫 파드 (500여 줄)
=== 파드 시작: writer-6b4dcfbc97-958m4 ===
=== 파드 시작: writer-5d45f94d66-k2bvl ===
=== 파드 시작: writer-5d45f94d66-42hxp ===   ← 네 번째 파드
```

**파드가 네 번 바뀌었는데 첫 파드의 기록이 그대로**입니다.
"쓰기가 이어진다"가 아니라 **"과거 데이터가 남아 있다"** 가 영속성의 증거입니다.
볼륨이 없어도 쓰기는 됩니다 — 파드가 죽으면 사라질 뿐입니다.

같은 디스크를 찾아가는 경로:
```
파드 → claimName: data-pvc → PV pvc-2b97fe60-... → EBS vol-07bceeadaa4a5393c
```
**파드는 바뀌어도 이 사슬은 고정**입니다. 그래서 새 파드도 항상 **2c 노드로만** 갔습니다.

### 콘솔의 "EBS 2개"는 CSI가 만든 게 아니다

| 볼륨 | 크기 | 장치 | CSI 태그 | 정체 |
|---|---|---|---|---|
| `vol-0c02cb...` | 20GB | `/dev/xvda` | 없음 | **노드 루트 디스크** (Day 3) |
| `vol-048289...` | 20GB | `/dev/xvda` | 없음 | **노드 루트 디스크** (Day 3) |
| `vol-07bcee...` | **1GB** | `/dev/xvdaa` | **`true`** | **PVC 볼륨** (Day 9) |

구분법: **크기**(20GB vs PVC에 적은 1Gi) · **장치명**(부팅 `xvda` vs 추가 부착 `xvdaa`) ·
**CSI 태그**(`ebs.csi.aws.com/cluster`).

## 실습 중 발견한 것 — 세 번의 교체 비교

핵심 목표는 아니었지만 **실무에서 사고가 자주 나는 지점**이라 기록합니다.

### 1차: 두 파드가 26초간 동시에 썼다

```
05:09:17 cvx2f
=== 파드 시작: 958m4 ===
05:09:21 958m4
05:09:22 cvx2f      ← 겹침
05:09:26 958m4
05:09:27 cvx2f      ← 겹침
...
05:09:47 cvx2f      ← 26초 동안
```

원인이 셋 겹쳤습니다.

**① RWO는 "파드 하나"가 아니라 "노드 하나"다**

두 파드가 모두 `ip-10-0-56-14`에 있어서 동시에 마운트할 수 있었습니다.
다른 노드였다면 `Multi-Attach error`로 막혔습니다.

| 모드 | 제한 단위 |
|---|---|
| `ReadWriteOnce` (RWO) | **노드** 하나 |
| `ReadWriteOncePod` (RWOP) | **파드** 하나 (1.29 GA) |
| `ReadWriteMany` (RWX) | 제한 없음 (EFS 등, EBS 불가) |

**② `strategy: Recreate`는 수동 삭제에 적용되지 않는다**

`kubectl delete pod`로 지우면 ReplicaSet이 "파드가 0개네"라며 **옛 파드의 종료를 기다리지 않고**
즉시 새 파드를 만듭니다. Recreate는 **롤아웃(템플릿 변경)** 에만 적용됩니다.

**③ 옛 파드가 30초를 꽉 채워 살았다**

```
05:09:17  옛 파드 마지막 정상 기록 → 이 무렵 삭제 요청
   + 30초 (terminationGracePeriodSeconds 기본값)
05:09:47  옛 파드 마지막 기록 → SIGKILL
```

`sh -c 'while true ...'`가 PID 1이면, 핸들러 없는 PID 1은 **SIGTERM을 무시**합니다.

### 수정: SIGTERM trap

```sh
trap 'echo "=== 종료 신호 수신: $(hostname) ===" >> /data/log.txt; exit 0' TERM
while true; do
  echo "..." >> /data/log.txt
  sleep 5 &
  wait $!        # 그냥 sleep 5 면 신호 처리가 최대 5초 늦어짐
done
```

### 2차: Recreate 롤아웃 — 겹침 없음

`kubectl apply`로 템플릿이 바뀌어 롤아웃이 일어났습니다.

```
05:14:11 958m4      ← 옛 파드 마지막
=== 파드 시작: k2bvl ===
05:14:16 k2bvl      ← 겹침 없음
```

Recreate가 옛 파드가 완전히 사라질 때까지 기다렸습니다.
다만 `958m4`는 **옛 템플릿**(trap 없음)이라 **약 30초 서비스 중단**이 있었을 겁니다.

> 이때 `kubectl delete pod`도 함께 쳤는데, 롤아웃이 이미 내리던 **옛 파드**를 지웠을 뿐
> 새 파드는 건드리지 않았습니다. 파드 이름의 ReplicaSet 해시(`6b4dcfbc97` vs `5d45f94d66`)로 구분됩니다.
> 옛 ReplicaSet은 `DESIRED 0`으로 남는데, `kubectl rollout undo`를 위한 이력입니다.

### 3차: 수동 삭제 + trap — 겹침 없음

```
05:21:21 k2bvl
=== 종료 신호 수신: k2bvl ===    ← SIGTERM을 받고 즉시 종료
=== 파드 시작: 42hxp ===
05:21:26 42hxp                   ← 겹침 없음
```

### 비교

| | 방식 | 옛 파드 | 겹침 | 비고 |
|---|---|---|---|---|
| **1차** | 수동 삭제 | trap 없음 | ❌ 26초 | 30초 채우고 SIGKILL |
| **2차** | Recreate 롤아웃 | trap 없음 | ✅ 없음 | 약 30초 중단 |
| **3차** | 수동 삭제 | **trap 있음** | ✅ 없음 | **몇 초 안에 종료** |

**1차와 3차는 똑같은 `kubectl delete pod`입니다.** 결과를 가른 건 애플리케이션의 SIGTERM 처리뿐입니다.

겹침을 막는 방법이 둘인데:

| 방법 | 수단 | 적용 범위 |
|---|---|---|
| Deployment가 기다려줌 | `strategy: Recreate` | 롤아웃만 |
| 앱이 빨리 죽음 | **SIGTERM 처리** | **모든 종료** (삭제·롤아웃·노드 축소·축출) |

**로그라 줄이 섞였을 뿐이지, DB였다면 파일이 손상됐을 겁니다.** 그래서 실무에서는
DB를 StatefulSet으로 띄우고, 필요하면 `ReadWriteOncePod`로 막고, 앱이 SIGTERM을 처리하게 만듭니다.

## ⚠️ 정리 — `make destroy`에 단계가 추가됐다

PVC가 만든 EBS는 **Day 8의 ALB처럼 Terraform state 밖**입니다.

```
Day 8  Gateway → ALB          (LB Controller가 생성)
Day 9  PVC     → EBS 볼륨     (EBS CSI 드라이버가 생성)
```

드라이버가 먼저 사라지면 볼륨을 지워줄 주체가 없습니다. `reclaimPolicy: Delete`여도
**삭제를 수행하는 게 드라이버**라서 드라이버가 살아 있을 때 PVC를 지워야 합니다.

```
── ① 쿠버네티스 오브젝트 삭제
   Day 8 Gateway        (→ LB Controller가 ALB 정리)
   Day 9 PVC·워크로드   (→ EBS CSI가 볼륨 정리)
── ② AWS 리소스가 사라질 때까지 대기 (ALB·EBS 함께, 최대 3분)
── ③ Helm으로 설치한 컨트롤러 제거
── ④ terraform destroy
```

- **PVC만 지우지 않고 워크로드째 지우는 이유**: `pvc-protection` finalizer 때문에
  쓰는 파드가 있으면 PVC가 `Terminating`에서 멈춥니다
- **EBS 필터**: `tag-key=ebs.csi.aws.com/cluster`. 드라이버가 만든 볼륨에 이 태그가 있고
  노드 루트 디스크엔 없는 것을 **양방향으로 검증**했습니다
- **대기를 한 번에 하는 이유**: ALB와 EBS 삭제는 서로 무관해 병렬로 진행됩니다

## 관찰 포인트

1. StorageClass를 먼저 만들었는데 왜 `csidriver`가 `NotFound`였나?
2. `WaitForFirstConsumer`에서 파드는 볼륨보다 먼저 "실행"되나?
3. controller와 node를 왜 나눴나? 각자 AWS 권한이 필요한가?
4. 콘솔의 EBS 볼륨 중 어느 게 PVC 것인지 세 가지 방법으로 구분할 수 있나?
5. RWO인데 두 파드가 동시에 쓸 수 있었던 이유는?
6. 같은 `kubectl delete pod`인데 1차와 3차 결과가 다른 이유는?

## 비용 메모

- 드라이버 자체는 **무료** (노드 자원만 사용)
- **gp3: GB-월 단위 과금**. 1GB를 몇 시간 쓰면 1센트 미만
- 노드 루트 디스크 20GB × 2는 Day 3부터 있던 것
- 시간당 합계는 그대로 **≈ $0.24** (EBS는 시간당으로 환산하면 미미)
- 단, **PVC를 남겨두면 destroy 후에도 볼륨이 과금**됩니다 → `make destroy`가 처리

## 다음 (Day 10)

**오토스케일링** — HPA(파드)와 Cluster Autoscaler/Karpenter(노드).
Day 3에서 "두뇌(오토스케일러) 없이 실행 장치(ASG)만 있다"고 한 곳에 두뇌를 끼웁니다.
오토스케일러도 AWS API를 부르니 **Day 7의 Pod Identity**가 또 쓰이고,
Terraform과 `desired_size`를 두고 충돌하는 문제(`ignore_changes`)를 만납니다.
