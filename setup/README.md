# Experimental Environment Setup

IEEE IoT Journal 논문의 실험에 사용한 **Container 및 MicroVM 환경 구축 방법**을 정리한다. 일반 Container 환경은 Kubernetes와 containerd를 사용하며, MicroVM 환경은 Kata Containers를 사용한다.

## 1. Setup 구성

| 문서 | 주요 내용 |
|---|---|
| [container.md](container.md) | containerd·Kubernetes 설치, Flannel 네트워크 구성, Worker Node 등록, 실험용 Pod 생성 및 삭제 |
| [microvm.md](microvm.md) | Raspberry Pi 4/5에서 Kata Containers 설치, Host 모듈 설정, Guest Kernel 준비 및 CCA 설정, Kata Runtime 등록 및 MicroVM 실행 |

## 2. 실험 환경

| 항목 | 구성 |
|---|---|
| Edge 장치 | Raspberry Pi 4, Raspberry Pi 5 (ARM64) |
| RPi4 OS / Host Kernel | Ubuntu 22.04 / `5.15.0-1105-raspi` (기존 설치 기록 기준) |
| RPi5 Host Kernel | Linux 6.8 계열 (정확한 버전은 실험 장치에서 확인) |
| Container 환경 | Kubernetes v1.29, containerd, Flannel |
| MicroVM 환경 | Kata Containers 3.24.0, Kata Guest Kernel 6.12.47 |
| Guest TCP Congestion Control | BBR (기본 Guest Kernel), CUBIC (별도 설정 시) |

> 소프트웨어의 정확한 패치 버전과 RPi5 OS/Host Kernel 버전은 논문 실험에 사용한 장치의 기록을 기준으로 확정한다.

## 3. 환경 구축 순서

### 3.1 Container 환경

1. [container.md](container.md)에 따라 Master 및 Worker Node에 containerd와 Kubernetes를 설치한다.
2. Master Node에서 클러스터를 초기화하고 Flannel을 설치한 후 Worker Node를 등록한다.
3. [container.md](container.md)의 Pod 생성 절차에 있는 `p1.yaml` 예시를 파일로 작성한 뒤, 안내된 명령어로 Pod를 생성한다.

### 3.2 MicroVM 환경

1. [microvm.md](microvm.md)에 따라 Raspberry Pi 4/5에 Kata Containers와 필요한 Host 모듈을 설치한다.
2. Host Kernel 모듈과 Kata Guest Kernel을 준비한다. 기본 Guest Kernel의 CCA는 BBR이며, CUBIC을 사용할 경우 [microvm.md](microvm.md)의 Guest Kernel 수정 과정을 따른다.
3. containerd에 Kata Runtime을 등록하고 `nerdctl`로 MicroVM 컨테이너를 생성하여 동작을 확인한다.
4. `nerdctl run --runtime io.containerd.kata.v2`로 Kata 컨테이너를 실행한다. Kubernetes RuntimeClass 설정은 필요하지 않다.

> 논문의 MicroVM 실험은 Kubernetes Pod가 아니라 `nerdctl`로 Kata를 직접 실행한 환경이다. `container.md`의 Kubernetes 설치는 일반 Container 실험용이며 MicroVM 실험의 필수 선행 단계는 아니다.

## 4. 다음 단계

환경 구축을 완료한 후, 제안 기법의 적용 방법과 성능 측정 절차는 저장소의 다음 문서를 참고한다.

- [ACA](../ACA/README.md): ACA 구현 및 적용
- [Pre-GSO](../Pre-GSO/README.md): Pre-GSO 커널 수정 및 적용
- [Experiments](../experiments/README.md): Netperf, Microservice, MicroVM, Time Window 및 Container Number 실험
