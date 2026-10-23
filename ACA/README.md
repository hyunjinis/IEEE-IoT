# ACA (Affinity-driven Core Alignment)

ACA는 네트워크 인터럽트가 집중된 CPU를 확인하고, 해당 CPU를 Pod의 실행 가능한 CPU 집합에서 제외하는 방식으로 적용한다. 이 문서는 **수정 kubelet 준비 → IRQ 분석 → Pod YAML annotation 생성 → Pod 생성 → cpuset 확인** 순서로 구성한다.

## 1. 구성

```text
ACA/
├── README.md
└── update_annotation.sh
```

- `update_annotation.sh`: Worker Node의 `/proc/interrupts`를 읽고 `p1.yaml`에 `example.com/SLO1`, `example.com/SLO2` annotation을 추가한다.
- [Kubernetes ACA 수정 커밋](https://github.com/hyunjinis/aca_kubernetes/commit/6e2970a38b2ee6d8995bd04d3146293c52328a0c): kubelet이 annotation을 읽어 Pod cgroup의 `cpuset.cpus`를 수정하도록 구현한 코드.
- 기본 Kubernetes 설치와 Pod YAML 작성은 [`../setup/container.md`](../setup/container.md) 참조.

> **버전:** ACA 수정 코드는 **Kubernetes v1.28** 기준이다. `setup/container.md` 역시 v1.28 환경으로 구성한다.

## 2. IRQ 확인 및 annotation 생성

### 2.1 SSH 및 스크립트 설정

Master에서 Worker의 `/proc/interrupts`를 읽을 수 있도록 SSH를 설정한다.

**Worker Node (SSH 서버)**

```bash
sudo apt-get update
sudo apt-get install -y openssh-server
sudo systemctl enable --now ssh
```

**Master Node (스크립트 실행)**

```bash
sudo apt-get update
sudo apt-get install -y openssh-client
ssh ubuntu4@192.168.0.252
```

Master에는 `yq` **v4(mikefarah/yq)** 가 필요하다. `yq --version`으로 설치 버전을 확인한다.

`update_annotation.sh`에서 Worker 주소, 인터페이스 및 임계 배수를 지정한다.

```bash
n=1
remote_host="192.168.0.252"
remote_user="ubuntu4"
network_interface="eth0"
input_yaml="p1.yaml"
output_yaml="p1-updated.yaml"
```

각 CPU에 대해 `eth0` 관련 IRQ의 **누적 카운트 합계**를 구한 뒤, 전체 코어의 평균을 계산한다.

```text
average = (CPU별 eth0 IRQ 누적 카운트의 합) / CPU 코어 수
threshold = average × n
bounded cores = IRQ 누적 카운트 > threshold 인 CPU
```

> `/proc/interrupts`는 부팅 이후의 **누적 횟수**를 제공한다. 여기서 `average`는 **CPU 간 평균값**이며 시간에 따른 평균 IRQ 발생률이 아니다. 실행 시점 및 NIC 이름에 따라 결과가 달라진다.

선택된 코어 중 **앞의 두 개**를 `SLO1`, `SLO2`로 저장한다. 선택된 코어가 두 개 미만이면 스크립트를 종료한다. 따라서 `n`을 변경할 때 두 코어 이상 선정되는지 확인한다.

### 2.2 YAML annotation 업데이트

`p1.yaml`이 있는 디렉터리에서 실행한다.

```bash
chmod +x update_annotation.sh
./update_annotation.sh
cat p1-updated.yaml
```

업데이트된 YAML의 예시는 다음과 같다.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: p1
  annotations:
    example.com/SLO1: "0"
    example.com/SLO2: "1"
spec:
  # 나머지 spec은 원래 p1.yaml을 유지
```

> `SLO1`, `SLO2`는 **Pod에서 제외할 CPU 번호**이다. `0`, `1`은 예시이며 실제 값은 IRQ 분석에 따라 달라진다. 이 스크립트는 서로 다른 코어가 두 개 미만으로 선정되면 종료한다.

### 2.3 Pod 생성

수정된 YAML로 **새 Pod를 생성**한다.

```bash
kubectl create -f p1-updated.yaml
kubectl get pod p1 -o wide
kubectl get pod p1 -o jsonpath='{.metadata.annotations.example\.com/SLO1}{" "}{.metadata.annotations.example\.com/SLO2}{"\n"}'
```

이미 `p1`이 존재하면 새 annotation이 kubelet의 cgroup 설정에 반드시 다시 적용된다고 가정하지 않는다. 재현할 때에는 기존 Pod를 삭제하고 새 YAML로 생성하는 방식이 명확하다.

```bash
kubectl delete pod p1
kubectl create -f p1-updated.yaml
```

## 3. 수정된 Kubernetes kubelet 적용

### 3.1 코드 가져오기

Worker Node에서 다음 **수정된 저장소와 커밋**을 기준으로 한다.

```bash
git clone https://github.com/hyunjinis/aca_kubernetes.git
cd aca_kubernetes
git checkout 6e2970a38b2ee6d8995bd04d3146293c52328a0c
```

이 저장소가 **완전한 Kubernetes 소스 트리인지, 변경 파일만 가진 저장소인지** 확인해야 한다. 변경 파일만 있다면 Kubernetes v1.28의 정확한 기준 커밋 소스에 아래 수정 파일을 옮겨 적용한다. 원본 커밋의 각 파일은 GitHub 링크에서 확인할 수 있다.

### 3.2 수정 코드 위치

| 경로 | ACA에서 하는 일 |
| --- | --- |
| `pkg/kubelet/necon/necon.go` | `SLO1`, `SLO2` 읽기, 허용 CPU 계산, `cpuset.cpus` 업데이트 |
| `pkg/kubelet/kuberuntime/kuberuntime_manager.go` | Pod 동기화 과정에서 `ApplyCPUAffinity()` 호출 |
| `pkg/kubelet/kubelet.go` | Pod 정보를 `necon` 객체에 전달 |
| `pkg/kubelet/cm/cgroup_manager_linux.go` | cgroup 경로를 `necon`에 전달 |
| `pkg/kubelet/kuberuntime/kuberuntime_container.go` | 컨테이너 ID 관련 `SetPID()` 호출 |
| `pkg/kubelet/necon/BUILD` | `necon` 빌드 정의 |

중요 구현은 `necon.go`의 다음 항목이다.

```go
s1, ok := pod.Annotations["example.com/SLO1"]
s2, ok := pod.Annotations["example.com/SLO2"]
// 문자열 CPU 번호 변환 후
allCores := []int{0, 1, 2, 3}
// 제외할 코어를 뺀 목록을 만들어 Pod cpuset.cpus에 기록
```

위 구현은 **4코어**, **BestEffort Pod**, **systemd/cgroup v2 경로**를 전제로 한다. 이외의 QoS 클래스나 cgroup 드라이버에서는 cgroup 경로가 달라질 수 있다.

### 3.3 kubelet 빌드 및 교체 (Worker Node)

ACA 수정 코드를 적용한 **전체 Kubernetes v1.28 소스**가 `~/kubernetes`에 준비되어 있어야 한다. 원본 코드는 [ACA 수정 커밋](https://github.com/hyunjinis/aca_kubernetes/commit/6e2970a38b2ee6d8995bd04d3146293c52328a0c)을 참고한다.

```bash
cd ~/kubernetes
make
```

> 기존 실험에서 사용한 `make` 명령을 그대로 기재했다. 전체 빌드는 시스템 자원을 많이 사용할 수 있다. kubelet만 빌드하려면 `make WHAT=cmd/kubelet`을 사용할 수도 있다.

빌드 산출물을 확인한다.

```bash
ls -l ~/kubernetes/_output/bin/kubelet
```

기존 kubelet을 백업하고 수정 바이너리로 교체한다. 아래 명령은 **kubelet 실행 파일이 `/usr/bin/kubelet`인 환경**을 기준으로 한다.

```bash
command -v kubelet
systemctl cat kubelet

sudo systemctl stop kubelet
sudo cp -a /usr/bin/kubelet /usr/bin/kubelet.backup
sudo cp ~/kubernetes/_output/bin/kubelet /usr/bin/kubelet
sudo chmod 755 /usr/bin/kubelet
sudo systemctl start kubelet
```

`/_output/bin/kubelet`은 루트 디렉터리를 가리키므로 사용하지 않는다. **`~/kubernetes/_output/bin/kubelet`**이 빌드 결과 경로다.

적용 여부 확인:

```bash
sudo systemctl status kubelet --no-pager
kubelet --version
sudo readlink -f /proc/$(pidof kubelet)/exe
sudo journalctl -u kubelet -n 50 --no-pager
```

문제가 발생하면 기존 바이너리로 복구한다.

```bash
sudo systemctl stop kubelet
sudo cp /usr/bin/kubelet.backup /usr/bin/kubelet
sudo systemctl start kubelet
```

> 바이너리 교체는 **Pod가 실행될 Worker Node**에서 수행한다. `kubelet.backup`이 이미 있다면 덮어쓰지 말고 다른 백업 이름을 사용한다.

## 4. cgroup CPU 적용 확인

Pod UID와 실행 노드를 확인한다.

```bash
kubectl get pod p1 -o wide
kubectl get pod p1 -o jsonpath='{.metadata.uid}{"\n"}'
```

Pod가 실행된 **Worker Node**에서 확인한다.

```bash
POD_UID='<kubectl에서 확인한 UID>'
CG_UID="${POD_UID//-/_}"
CG="/sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod${CG_UID}.slice"

cat "$CG/cpuset.cpus"
cat "$CG/cpuset.cpus.effective"
```

예를 들어 SLO1=0, SLO2=1이고 CPU가 0~3이면 허용 CPU는 `2,3`이 된다. 실제 실행 가능 범위는 `cpuset.cpus.effective`에서 확인한다.

로그에서 ACA 관련 메시지 및 실패를 확인한다.

```bash
sudo journalctl -u kubelet --no-pager | grep -E 'ApplyCPUAffinity|Allowed Cores|CGroup 경로|CPU affinity'
```

**주의:** 실제 커밋에서 `ApplyCPUAffinity()` 호출은 sandbox 변경 처리 경로에 있으며, cgroup 생성 타이밍에 따라 지정된 경로가 존재하지 않아 실패할 수 있다. 따라서 annotation만 확인하지 말고 **실제 `cpuset.cpus.effective`까지 반드시 검사**한다.

## 5. 정리 및 참고

```bash
kubectl delete pod p1
```

- ACA 수정 Kubernetes 소스: <https://github.com/hyunjinis/aca_kubernetes>
- 수정 커밋: <https://github.com/hyunjinis/aca_kubernetes/commit/6e2970a38b2ee6d8995bd04d3146293c52328a0c>

실험용 성능 측정 스크립트는 `../experiments/netperf/`에서 별도로 정리한다.
