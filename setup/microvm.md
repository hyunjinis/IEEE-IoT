# MicroVM Environment Setup (Kata Containers)

본 문서는 Raspberry Pi 4/5에서 **Kata Containers 3.24.0**을 설치하고 Guest Kernel을 구성하는 방법을 정리한다. **기존 Guest Kernel의 기본 TCP CCA는 BBR**이며, 아래에는 실험 조건에 따라 **CUBIC을 기본값으로 변경한 Guest Kernel**을 빌드하는 절차도 포함한다. 일반 Kubernetes 기반 Container 환경 구축은 [container.md](container.md)를 참고한다. **Kata 실험은 Kubernetes RuntimeClass를 사용하지 않고 `nerdctl`로 직접 실행한다.**

기존 설치 기록: [kata-install-with-rpi5](https://github.com/hyunjinis/kata-install-with-rpi5) (`rpi4(v5.15).md`, `rpi5(v6.8).md`).

## 1. 설치 환경

| 항목 | 설정 |
|---|---|
| 장치 | Raspberry Pi 4 / Raspberry Pi 5 (ARM64) |
| RPi4 Host OS | Ubuntu 22.04 |
| RPi4 Host Kernel | `5.15.0-1105-raspi` |
| RPi5 Host Kernel | `6.8.0-1044-raspi` |
| Kata Containers | `3.24.0` |
| Kata Guest Kernel | `6.12.47` |
| nerdctl | `2.2.1` |
| Guest TCP CCA | BBR (기본 배포 구성), CUBIC (아래 커스텀 빌드 적용 시) |

> Host Kernel과 Kata Guest Kernel은 서로 다르다. 아래의 `6.12.47` 빌드 과정은 **Kata Guest Kernel**에 대한 것이다.

## 2. Kata Containers 설치 (RPi4 / RPi5)

```bash
sudo apt update
wget https://github.com/kata-containers/kata-containers/releases/download/3.24.0/kata-static-3.24.0-arm64.tar.zst
sudo tar -xvf kata-static-3.24.0-arm64.tar.zst -C /
rm -f kata-static-3.24.0-arm64.tar.zst

sudo ln -sfn /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime
sudo ln -sfn /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
sudo ln -sfn /opt/kata/bin/kata-collect-data.sh /usr/local/bin/kata-collect-data.sh

kata-runtime --version
```

## 3. Host Kernel 모듈 설정

### Raspberry Pi 5

```bash
sudo modprobe vhost
sudo modprobe vhost_net
sudo modprobe vhost_vsock
sudo kata-runtime check
```

### Raspberry Pi 4 (Host Kernel 5.15)

RPi4의 기존 설치 기록에서는 Kata 네트워크 실행에 `xfrm_user` 모듈이 추가로 필요했다.

```bash
sudo apt update
sudo apt install -y linux-modules-extra-$(uname -r)

sudo modprobe xfrm_user
sudo modprobe vhost
sudo modprobe vhost_net
sudo modprobe vhost_vsock
sudo modprobe sch_ingress
sudo modprobe cls_u32
sudo modprobe act_mirred

sudo kata-runtime check
```

모듈을 재부팅 후에도 자동 로드하려면 다음 파일을 추가한다.

```bash
cat <<'EOF' | sudo tee /etc/modules-load.d/kata.conf
xfrm_user
vhost
vhost_net
vhost_vsock
sch_ingress
cls_u32
act_mirred
EOF
```

> RPi4의 추가 모듈 패키지가 설치되지 않거나 `modprobe`가 실패하면 Host Kernel의 모듈 지원을 확인한다.

## 4. Guest Kernel 빌드 도구 설치

```bash
sudo apt update
sudo apt install -y flex bison libelf-dev libncurses-dev curl git build-essential bc libssl-dev
```

### Go 설치

```bash
wget https://go.dev/dl/go1.26.0.linux-arm64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.26.0.linux-arm64.tar.gz
rm -f go1.26.0.linux-arm64.tar.gz

echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
go version
```

### Rust 설치

```bash
curl https://sh.rustup.rs -sSf | sh -s -- -y
source "$HOME/.cargo/env"
rustc --version
cargo --version
```

### yq 설치

```bash
go install github.com/mikefarah/yq/v4@v4.52.4
sudo cp "$HOME/go/bin/yq" /usr/local/bin/yq
yq --version
```

## 5. Kata Guest Kernel 준비

```bash
git clone https://github.com/kata-containers/kata-containers.git ~/kata-containers
cd ~/kata-containers/tools/packaging/kernel
./build-kernel.sh -a aarch64 -v 6.12.47 -f -d setup
```

> 기존 기록에서는 Kata 소스의 기본 브랜치를 사용했다. 논문 실험을 정확히 재현하려면 빌드에 사용한 Kata Git commit을 확인해 고정한다.

```bash
CFG=$(cat kata_config_version)
KDIR="$PWD/kata-linux-6.12.47-$CFG"
echo "$KDIR"
```

## 6. Guest Kernel의 기본 CCA를 CUBIC으로 변경 (CUBIC 실험 시)

```bash
"$KDIR/scripts/config" \
  --file "$KDIR/.config" \
  -e TCP_CONG_CUBIC \
  -e TCP_CONG_BBR \
  -e DEFAULT_CUBIC \
  -d DEFAULT_BBR

make -C "$KDIR" ARCH=arm64 olddefconfig
```

```bash
grep -E 'CONFIG_TCP_CONG_(CUBIC|BBR)|CONFIG_DEFAULT_(CUBIC|BBR)|CONFIG_DEFAULT_TCP_CONG' "$KDIR/.config"
```

정상 설정:

```text
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_CUBIC=y
# CONFIG_DEFAULT_BBR is not set
CONFIG_DEFAULT_TCP_CONG="cubic"
```

> `.config` 수정 후 `setup -f`를 다시 실행하면 설정이 초기화될 수 있다.

## 7. Guest Kernel 빌드 및 설치

```bash
cd ~/kata-containers/tools/packaging/kernel
./build-kernel.sh -a aarch64 -v 6.12.47 -d build
sudo ./build-kernel.sh -a aarch64 -v 6.12.47 -d install
```

생성 파일 확인:

```bash
ls -lh "$KDIR/arch/arm64/boot/Image" "$KDIR/vmlinux"
ls -lh /usr/share/kata-containers/
```

### Static Kata 경로에 Guest Kernel 복사

```bash
sudo cp -a /opt/kata/share/kata-containers/vmlinuz.container \
  /opt/kata/share/kata-containers/vmlinuz.container.backup
sudo cp -a /opt/kata/share/kata-containers/vmlinux.container \
  /opt/kata/share/kata-containers/vmlinux.container.backup

sudo cp "/usr/share/kata-containers/vmlinuz-6.12.47-$CFG" \
  "/opt/kata/share/kata-containers/vmlinuz-6.12.47-$CFG"
sudo cp "/usr/share/kata-containers/vmlinux-6.12.47-$CFG" \
  "/opt/kata/share/kata-containers/vmlinux-6.12.47-$CFG"
sudo cp "/usr/share/kata-containers/config-6.12.47-$CFG" \
  "/opt/kata/share/kata-containers/config-6.12.47-$CFG"

cd /opt/kata/share/kata-containers
sudo ln -sfn "vmlinuz-6.12.47-$CFG" vmlinuz.container
sudo ln -sfn "vmlinux-6.12.47-$CFG" vmlinux.container

sudo kata-runtime env | grep -i -A5 kernel
```

> 여기서는 CUBIC 기반의 기본 Guest Kernel만 준비한다. **Pre-GSO 커널 수정과 Baseline/Pre-GSO 커널 전환은 [`../Pre-GSO/README.md`](../Pre-GSO/README.md)**에서 별도로 설명한다.

## 8. containerd에 Kata Runtime 등록

```bash
sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
sudo nano /etc/containerd/config.toml
```

containerd **2.x**에서는 다음 블록을 추가한다.

```toml
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
```

containerd **1.x**에서는 다음 블록을 사용한다.

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
```

> 두 예시 중 사용 중인 containerd 설정에 맞는 **하나만** 추가하고, 기존 `runc` 블록은 유지한다.

```bash
sudo systemctl restart containerd
sudo systemctl status containerd --no-pager
sudo containerd config dump | grep -A5 -B2 kata
```

## 9. nerdctl 설치 및 Kata Container 생성

논문의 MicroVM 실험에서는 Kubernetes Pod가 아닌 `nerdctl`을 이용해 Kata 컨테이너를 직접 생성한다.

```bash
wget https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-2.2.1-linux-arm64.tar.gz
tar xzvf nerdctl-2.2.1-linux-arm64.tar.gz
sudo install -m 755 nerdctl /usr/local/bin/nerdctl
rm -f nerdctl-2.2.1-linux-arm64.tar.gz
nerdctl --version
```

### CNI 설정 (nerdctl 직접 실행에 한정)

기존 저장소는 `nerdctl`을 위한 CNI Bridge 네트워크를 사용했다. Kubernetes Flannel이 이미 설치된 노드에서 **동일한 `cni0` 브리지를 중복 생성하면 충돌**할 수 있으므로, 이 단계는 **별도의 nerdctl 실행 환경에서만** 진행한다.

```bash
ls /opt/cni/bin/bridge
sudo mkdir -p /etc/cni/net.d
sudo tee /etc/cni/net.d/10-mynet.conf > /dev/null <<'CNI_EOF'
{
  "cniVersion": "0.2.0",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "subnet": "172.19.0.0/24",
    "routes": [{"dst": "0.0.0.0/0"}]
  }
}
CNI_EOF
```

> 기존 기록의 DNS 주소 등은 사이트별 설정이어서 여기서는 제외했다. Kubernetes에 이미 CNI가 구성된 경우에는 이 파일을 추가하지 않는다.

Kata 컨테이너 생성:

```bash
sudo nerdctl run -d \
  --name kata-test \
  --runtime io.containerd.kata.v2 \
  jjong2/all:latest \
  sleep infinity
sudo nerdctl ps
```

Guest 확인:

```bash
sudo nerdctl exec kata-test uname -r
sudo nerdctl exec kata-test sysctl net.ipv4.tcp_congestion_control
sudo nerdctl exec kata-test cat /proc/sys/net/ipv4/tcp_available_congestion_control
```

Guest Kernel은 `6.12.47`이며, 기본 배포 커널의 CCA는 `bbr`이다. 위에서 CUBIC 커널을 직접 빌드·적용했다면 `cubic`으로 확인된다.

컨테이너 삭제:

```bash
sudo nerdctl rm -f kata-test
```

## 10. 최종 확인

Host:

```bash
kata-runtime --version
sudo kata-runtime check
sudo containerd config dump | grep -A5 -B2 kata
sudo kata-runtime env | grep -i -A5 kernel
```

Kata Guest (`kata-test` 실행 중):

```bash
sudo nerdctl exec kata-test uname -r
sudo nerdctl exec kata-test sysctl net.ipv4.tcp_congestion_control
```

**참고:** [RPi4 설치 원본](https://github.com/hyunjinis/kata-install-with-rpi5/blob/main/rpi4%28v5.15%29.md) · [RPi5 설치 원본](https://github.com/hyunjinis/kata-install-with-rpi5/blob/main/rpi5%28v6.8%29.md) · [Guest Kernel 교체 원본](https://github.com/hyunjinis/kata-install-with-rpi5/blob/main/custom%20kernel.md)
