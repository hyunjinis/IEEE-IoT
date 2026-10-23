# MicroVM Environment Setup (Kata Containers)

Raspberry Pi 4/5에서 **Kata Containers를 `nerdctl`로 직접 실행**하는 환경을 구성한다. Kubernetes RuntimeClass는 사용하지 않는다. **기본 Guest Kernel의 TCP CCA는 BBR**이며, CUBIC 사용을 위한 Guest Kernel 설정·빌드 및 Guest 내부에서의 CCA 전환 방법까지 다룬다. Pre-GSO **소스코드 수정**은 [`../Pre-GSO/README.md`](../Pre-GSO/README.md), 성능 측정은 [`../experiments/microvm/README.md`](../experiments/microvm/README.md)를 참고한다.

## 1. 실험 환경

| 항목 | 설정 |
|---|---|
| 장치 | Raspberry Pi 4 / Raspberry Pi 5 (`aarch64`) |
| RPi4 Host OS / Kernel | Ubuntu 22.04 / `5.15.0-1105-raspi` (기존 기록) |
| RPi5 Host Kernel | 6.8 계열 (실제 `uname -r`로 정확한 값 기록) |
| Kata Containers | `3.24.0` |
| Kata Guest Kernel | Linux `6.12.47` |
| nerdctl | `2.2.1` |
| Guest TCP CCA | 기본 BBR / 추가 구성 시 CUBIC·BBR 선택 가능 |

Host Kernel과 Kata Guest Kernel은 서로 다르다. 아래의 커널 빌드 과정은 **Kata Guest Kernel**에 적용한다.

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

### RPi5

```bash
sudo modprobe vhost
sudo modprobe vhost_net
sudo modprobe vhost_vsock
lsmod | grep -E 'vhost|vsock|tap'
sudo kata-runtime check
```

### RPi4 (Host Kernel 5.15)

기존 RPi4 설치 기록에서는 `xfrm_user`가 없으면 Kata 네트워크 생성 시 `protocol not supported`가 발생할 수 있었다.

```bash
uname -r
sudo apt update
sudo apt install -y linux-modules-extra-$(uname -r)

sudo modprobe xfrm_user
sudo modprobe vhost
sudo modprobe vhost_net
sudo modprobe vhost_vsock
sudo modprobe sch_ingress
sudo modprobe cls_u32
sudo modprobe act_mirred

lsmod | grep -E 'xfrm|vhost|tap|sch_ingress|cls_u32|act_mirred'
sudo kata-runtime check
```

재부팅 후 모듈을 자동으로 로드하려면 다음을 추가한다.

```bash
cat <<'EOF_MODULES' | sudo tee /etc/modules-load.d/kata.conf
xfrm_user
vhost
vhost_net
vhost_vsock
sch_ingress
cls_u32
act_mirred
EOF_MODULES
```

필요한 장치·Netlink 지원 확인 (RPi4에서 네트워크 문제 발생 시):

```bash
ls -l /dev/kvm /dev/net/tun /dev/vhost-vsock 2>/dev/null
python3 - <<'PY'
import socket
for p, name in [(0, 'NETLINK_ROUTE'), (6, 'NETLINK_XFRM'), (12, 'NETLINK_NETFILTER')]:
    try:
        s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, p)
        print(name, 'OK')
        s.close()
    except OSError as e:
        print(name, 'FAIL', e)
PY
```

## 4. Guest Kernel 빌드 도구 설치

```bash
sudo apt update
sudo apt install -y flex bison libelf-dev libncurses-dev \
  curl git build-essential bc libssl-dev
```

### Go

기존 설치 기록에서 사용한 Go 버전:

```bash
wget https://go.dev/dl/go1.26.0.linux-arm64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.26.0.linux-arm64.tar.gz
rm -f go1.26.0.linux-arm64.tar.gz

echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
hash -r
which go
go version
```

### Rust

```bash
curl https://sh.rustup.rs -sSf | sh -s -- -y
source "$HOME/.cargo/env"
rustc --version
cargo --version
```

### yq

```bash
go install github.com/mikefarah/yq/v4@v4.52.4
sudo install -m 755 "$HOME/go/bin/yq" /usr/local/bin/yq
yq --version
```

## 5. Kata Guest Kernel 6.12.47 준비

```bash
git clone https://github.com/kata-containers/kata-containers.git ~/kata-containers
cd ~/kata-containers
# 기존 설치 메모는 기본 브랜치를 사용했음. 재현 시에는 실제 빌드에 사용한 commit을 고정한다.
git rev-parse HEAD

cd tools/packaging/kernel
./build-kernel.sh -a aarch64 -v 6.12.47 -f -d setup

CFG=$(cat kata_config_version)
KDIR="$PWD/kata-linux-6.12.47-$CFG"
echo "$KDIR"
```

`CFG`는 실제 `kata_config_version` 값으로 결정되므로 `202` 등 특정 숫자를 고정해서 쓰지 않는다.

## 6. Guest Kernel의 BBR / CUBIC 설정

기본 Kata Guest Kernel의 CCA가 BBR인지 먼저 확인한다. **CUBIC을 `sysctl`로 선택하려면 Guest Kernel에 CUBIC 지원이 포함되어 있어야 한다.** 기존 설치 저장소에서는 CUBIC을 built-in으로 추가하고 CUBIC을 기본값으로 설정한 커널을 따로 빌드했다.

### 6.1 기본 BBR 설정 확인

```bash
grep -E 'CONFIG_TCP_CONG_(CUBIC|BBR)|CONFIG_DEFAULT_(CUBIC|BBR)|CONFIG_DEFAULT_TCP_CONG' "$KDIR/.config"
```

### 6.2 BBR을 기본값으로 유지하면서 CUBIC도 사용할 수 있도록 빌드 (권장)

```bash
"$KDIR/scripts/config" --file "$KDIR/.config" \
  -e TCP_CONG_CUBIC \
  -e TCP_CONG_BBR \
  -e DEFAULT_BBR \
  -d DEFAULT_CUBIC

make -C "$KDIR" ARCH=arm64 olddefconfig
```

확인:

```bash
grep -E 'CONFIG_TCP_CONG_(CUBIC|BBR)|CONFIG_DEFAULT_(CUBIC|BBR)|CONFIG_DEFAULT_TCP_CONG' "$KDIR/.config"
```

기대 설정:

```text
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_BBR=y
# CONFIG_DEFAULT_CUBIC is not set
CONFIG_DEFAULT_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"
```

### 6.3 CUBIC을 기본값으로 하는 Guest Kernel이 필요할 경우

기존 RPi4/RPi5 저장소에 기록된 CUBIC 기본 커널의 빌드 설정은 다음과 같다.

```bash
"$KDIR/scripts/config" --file "$KDIR/.config" \
  -e TCP_CONG_CUBIC \
  -e TCP_CONG_BBR \
  -e DEFAULT_CUBIC \
  -d DEFAULT_BBR

make -C "$KDIR" ARCH=arm64 olddefconfig
```

**6.2와 6.3 중 필요한 설정 하나를 적용한다.** 같은 Guest Kernel에서 BBR과 CUBIC이 모두 built-in이면, 실행 후 `sysctl`로 변경할 수 있으므로 실험마다 새 커널을 빌드할 필요는 없다. `.config` 수정 후 `setup -f`를 다시 실행하면 설정이 덮어써질 수 있다.

## 7. Guest Kernel 빌드 및 설치

```bash
cd ~/kata-containers/tools/packaging/kernel
CFG=$(cat kata_config_version)
KDIR="$PWD/kata-linux-6.12.47-$CFG"

./build-kernel.sh -a aarch64 -v 6.12.47 -d build
sudo ./build-kernel.sh -a aarch64 -v 6.12.47 -d install

ls -lh "$KDIR/vmlinux" "$KDIR/arch/arm64/boot/Image"
ls -lh /usr/share/kata-containers/
```

Static Kata 설치 경로(`/opt/kata/`)에 빌드한 커널을 복사한다.

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

readlink -f vmlinuz.container
readlink -f vmlinux.container
sudo kata-runtime env | grep -i -A5 kernel
```

커널 파일을 교체했다면 **기존 Kata MicroVM을 종료하고 새로 생성**해야 적용된다. Pre-GSO 코드 수정·별도 커널 빌드와 Baseline/Pre-GSO 교체는 [`../Pre-GSO/README.md`](../Pre-GSO/README.md)에서 다룬다.

## 8. Kata Runtime 설정

기존 RPi4 기록의 QEMU 설정을 사용한다.

```bash
sudo mkdir -p /etc/kata-containers
sudo cp /opt/kata/share/defaults/kata-containers/configuration-qemu.toml \
  /etc/kata-containers/configuration.toml

sudo nano /etc/kata-containers/configuration.toml
```

일반 네트워크 사용 시 다음 항목을 확인한다.

```toml
internetworking_model = "tcfilter"
disable_new_netns = false
```

```bash
grep -nE '^[[:space:]]*(internetworking_model|disable_new_netns)[[:space:]]*=' \
  /etc/kata-containers/configuration.toml
sudo kata-runtime env | grep -E 'Config|Path|Kernel' -A3
```

### containerd에 Kata Runtime 등록

기존 containerd 설정을 백업하고 `runc` 설정을 유지한 상태로 Kata 항목을 추가한다.

```bash
containerd --version
sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
sudo nano /etc/containerd/config.toml
```

containerd 2.x에서는 기존 `runc`와 같은 namespace 아래에 다음 항목을 추가한다.

```toml
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
```

containerd 1.x에서는 다음 형식을 사용한다.

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
```

**둘 중 실제 containerd 버전에 맞는 것만 추가**한다. 이 항목은 CRI용 설정이며, `nerdctl --runtime io.containerd.kata.v2` 자체는 Kata shim이 검색 가능하면 직접 실행할 수 있다. 다만 기존 구축 내역을 재현하기 위해 등록 과정도 남긴다.

```bash
sudo systemctl restart containerd
sudo systemctl status containerd --no-pager
sudo containerd config dump | grep -A5 -B2 kata
```

## 9. CNI 및 nerdctl 설정

### 9.1 CNI Plugins

```bash
sudo apt update
sudo apt install -y kubernetes-cni
ls /opt/cni/bin/
ls /opt/cni/bin/bridge /opt/cni/bin/host-local /opt/cni/bin/loopback
```

### 9.2 nerdctl 2.2.1 설치

```bash
wget https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-2.2.1-linux-arm64.tar.gz
tar xzvf nerdctl-2.2.1-linux-arm64.tar.gz
sudo install -m 755 nerdctl /usr/local/bin/nerdctl
rm -f nerdctl-2.2.1-linux-arm64.tar.gz
nerdctl --version
```

### 9.3 CNI 네트워크 구성

기존 설치 기록에는 **두 가지 방식**이 사용되었다. 한 환경에서 두 방식을 동시에 설정하지 않는다.

**A. RPi4 기록: nerdctl `kata-net` 생성**

```bash
sudo nerdctl network create kata-net
sudo nerdctl network ls
sudo nerdctl network inspect kata-net
```

이 경우 Kata 생성 시 `--network kata-net`을 지정한다.

**B. RPi5 기록: CNI Bridge 설정 파일 직접 생성**

```bash
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
  },
  "dns": {
    "nameservers": ["155.230.10.2"]
  }
}
CNI_EOF

cat /etc/cni/net.d/10-mynet.conf
sudo systemctl restart containerd
```

`155.230.10.2`는 기존 RPi5 설치 기록의 DNS 설정이다. 해당 네트워크에서 사용할 수 없으면 실제 DNS로 변경한다. Kubernetes Flannel이 기존에 `cni0` 등을 사용 중이면 새 CNI 브리지 구성이 충돌할 수 있으므로 별도 네트워크 환경에서 설정한다.

## 10. Kata Container 생성 및 확인

### 10.1 기본 실행 (nerdctl)

RPi5 설치 기록의 기본 실행 방식:

```bash
sudo nerdctl run \
  -it \
  --rm \
  --runtime io.containerd.kata.v2 \
  ubuntu:22.04 \
  sh
```

RPi4에서 `kata-net`을 만든 경우:

```bash
sudo nerdctl run \
  -it \
  --rm \
  --network kata-net \
  --runtime io.containerd.kata.v2 \
  ubuntu:22.04 \
  sh
```

기본 Ubuntu 이미지에서 네트워크 확인 도구가 없다면 **Guest 내부**에서 설치한다.

```bash
apt update
apt install -y iproute2 iputils-ping procps
ip addr
ip route
ping -c 3 1.1.1.1
```

`exit`로 나가면 `--rm` 옵션에 의해 컨테이너가 삭제된다.

### 10.2 실험용 컨테이너 상시 실행

```bash
sudo nerdctl run -d \
  --name kata-test \
  --runtime io.containerd.kata.v2 \
  jjong2/all:latest \
  sleep infinity

sudo nerdctl ps
sudo nerdctl exec -it kata-test /bin/bash
```

RPi4의 명시적 네트워크를 사용하는 경우 `run` 명령어에 `--network kata-net`을 추가한다.

### 10.3 Guest Kernel 및 CCA 확인

다음 명령은 **Kata Guest 내부에서 실행**한다 (`nerdctl exec`로 호출해도 됨).

```bash
uname -r
sysctl net.ipv4.tcp_congestion_control
cat /proc/sys/net/ipv4/tcp_available_congestion_control
```

기본 배포 Guest Kernel은 BBR로 설정된 상태이며, 6장에서 CUBIC·BBR 지원을 함께 빌드했다면 두 알고리즘이 목록에 나타난다.

### 10.4 Guest TCP CCA 변경

다음은 **Guest 내부에서만** 실행한다. 먼저 `tcp_available_congestion_control` 목록에 대상 알고리즘이 있는지 확인한다.

```bash
# CUBIC 선택
sysctl -w net.ipv4.tcp_congestion_control=cubic

# BBR 선택
sysctl -w net.ipv4.tcp_congestion_control=bbr

# 현재 설정 확인
sysctl net.ipv4.tcp_congestion_control
```

권한 오류가 나면 Guest의 root 권한에서 실행해야 한다. 변경은 해당 Guest의 네트워크 namespace에 적용되며, 새 MicroVM에는 지속되지 않을 수 있으므로 컨테이너 재생성 후 다시 확인한다.

### 10.5 컨테이너 삭제

```bash
sudo nerdctl rm -f kata-test
```

## 11. 최종 확인

**Host:**

```bash
kata-runtime --version
sudo kata-runtime check
nerdctl --version
sudo kata-runtime env | grep -i -A5 kernel
sudo containerd config dump | grep -A5 -B2 kata
```

**Kata Guest (`kata-test` 실행 중):**

```bash
sudo nerdctl exec kata-test uname -r
sudo nerdctl exec kata-test sysctl net.ipv4.tcp_congestion_control
sudo nerdctl exec kata-test cat /proc/sys/net/ipv4/tcp_available_congestion_control
```

## 12. 문제가 발생할 경우

| 현상 | 확인할 부분 |
|---|---|
| `protocol not supported` (RPi4) | `xfrm_user`, `linux-modules-extra-$(uname -r)` 및 `NETLINK_XFRM` 지원 |
| Kata 실행 시 네트워크 생성 실패 | CNI 플러그인, `/etc/cni/net.d/`, `kata-net`, 중복 브리지, `tcfilter` 설정 |
| CUBIC으로 변경할 수 없음 | Guest Kernel의 `CONFIG_TCP_CONG_CUBIC=y` 및 Guest 내 available CCA 목록 |
| `uname -r`는 같지만 다른 커널이 실행됨 | `sudo kata-runtime env`의 kernel 경로 및 `/opt/kata/share/kata-containers/` symlink |
| Guest Kernel 교체 후 적용되지 않음 | 기존 Kata 컨테이너 종료 후 새로 생성했는지 확인 |
| `install: Permission denied` | Guest Kernel 설치 명령을 `sudo ./build-kernel.sh ... install`로 실행 |

## 참고

- [RPi4 설치 원본](https://github.com/hyunjinis/kata-install-with-rpi5/blob/main/rpi4%28v5.15%29.md)
- [RPi5 설치 원본](https://github.com/hyunjinis/kata-install-with-rpi5/blob/main/rpi5%28v6.8%29.md)
- [Guest Kernel 수정·교체 원본](https://github.com/hyunjinis/kata-install-with-rpi5/blob/main/custom%20kernel.md)
