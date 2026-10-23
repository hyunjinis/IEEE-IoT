# Kubernetes Container Setup

Ubuntu 기반 Master 및 Worker Node에 containerd, Kubernetes v1.29, Flannel을 설치한다.

**실행 위치:** 1-3단계는 Master&Worker 공통, 4-5단계는 Master, 6단계는 Worker에서 실행한다.

## 1. Network 및 Kernel 설정 (Master / Worker)

### Network settings

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

### Kernel parameter settings

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system
```

### Swap off

```bash
sudo swapoff -a
sudo cp /etc/fstab /etc/fstab.bak
sudo sed -i -E '/^[[:space:]]*[^#].*[[:space:]]swap[[:space:]]/ s/^/# /' /etc/fstab
```

### Raspberry Pi cgroup

`/boot/firmware/cmdline.txt` 파일의 **기존 한 줄 끝에** 다음 옵션을 추가한다.

```text
cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
```

> `cmdline.txt`는 한 줄로 유지한다. 수정한 경우 재부팅 후 진행한다.

## 2. Install containerd (Master / Worker)

```bash
sudo apt-get update
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl daemon-reload
sudo systemctl enable --now containerd
sudo systemctl restart containerd
```

> `SystemdCgroup = true`가 설정되었는지 확인한다. containerd 1.x와 2.x는 CRI plugin 설정 경로가 다르므로 해당 버전의 `config.toml`을 기준으로 수정한다.

```bash
containerd --version
grep -n SystemdCgroup /etc/containerd/config.toml
```

## 3. Install Kubernetes (Master / Worker)

### Install dependencies

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
```

### Kubernetes v1.29 repository

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
```

### Install kubelet, kubeadm, kubectl

```bash
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

> 다른 Kubernetes minor version을 사용할 경우 Repository URL의 `v1.29`를 두 곳 모두 변경한다.

## 4. Initialize Kubernetes Cluster (Master)

`<MASTER_IP>`를 Master의 실제 IP 주소로 변경한다.

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=<MASTER_IP> \
  --cri-socket unix:///run/containerd/containerd.sock
```

```bash
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

## 5. Install Flannel (Master)

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

> 재현할 실험의 Flannel 버전이 정해져 있다면 `latest` 대신 해당 버전의 manifest를 사용한다. Pod CIDR은 `10.244.0.0/16`을 사용한다.

## 6. Join Worker Nodes

Master에서 Join 명령어를 생성한다.

```bash
sudo kubeadm token create --print-join-command
```

출력된 명령어를 각 Worker에서 `sudo`로 실행한다. containerd 소켓까지 지정하는 경우:

```bash
sudo kubeadm join <MASTER_IP>:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --cri-socket unix:///run/containerd/containerd.sock
```

> `<TOKEN>`과 `<HASH>`는 생성된 값으로 변경한다. Join 명령어는 `kubeadm init` 완료 후 생성한다.

## 7. Verify (Master)

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

모든 Node가 `Ready` 상태이고 Flannel Pod가 실행 중인지 확인한다.

## References

- [Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Flannel](https://github.com/flannel-io/flannel)
