#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Install the CUDA 12.9 toolkit (Ubuntu 24.04 / Armbian Noble, aarch64 "sbsa")
# from NVIDIA's apt repository, then build and run the M10 CUDA self-test.
#
# CUDA 12.9 is the last toolkit that can compile for Maxwell (sm_50); 13.x can't.
# Only the toolkit is installed - NOT a driver (the patched driver from
# scripts/install.sh provides libcuda).
#
# *** UNTESTED WORK IN PROGRESS. ***
#
#   sudo scripts/setup-cuda.sh            # install toolkit + run self-test
#   scripts/setup-cuda.sh --test-only     # just build + run the self-test
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
CUDA_VER=12-9
CUDA_HOME=/usr/local/cuda-12.9
REPO_URL=https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/sbsa

if [ "${1:-}" != "--test-only" ]; then
    [ "$(id -u)" = 0 ] || { echo "Run as root (sudo), or use --test-only."; exit 1; }
    [ "$(uname -m)" = aarch64 ] || { echo "aarch64 only."; exit 1; }

    echo ">> Adding NVIDIA CUDA apt repository (ubuntu2404/sbsa)"
    tmp=$(mktemp -d)
    if command -v wget >/dev/null; then
        wget -q -O "$tmp/cuda-keyring.deb" "$REPO_URL/cuda-keyring_1.1-1_all.deb"
    else
        curl -fsSL -o "$tmp/cuda-keyring.deb" "$REPO_URL/cuda-keyring_1.1-1_all.deb"
    fi
    dpkg -i "$tmp/cuda-keyring.deb"
    rm -rf "$tmp"

    # Keep apt from ever pulling NVIDIA driver packages over the patched driver.
    cat > /etc/apt/preferences.d/m10-no-nvidia-driver <<'P'
Package: nvidia-driver-* nvidia-kernel-* nvidia-dkms-* cuda-drivers* libnvidia-compute-* nvidia-open*
Pin: release *
Pin-Priority: -1
P

    apt-get update
    apt-get install -y --no-install-recommends "cuda-toolkit-$CUDA_VER"

    cat > /etc/profile.d/cuda-12.9.sh <<E
export PATH=$CUDA_HOME/bin:\$PATH
export LD_LIBRARY_PATH=$CUDA_HOME/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
E
    echo ">> Toolkit installed; open a new shell (or: . /etc/profile.d/cuda-12.9.sh)"
fi

NVCC=${NVCC:-$CUDA_HOME/bin/nvcc}
[ -x "$NVCC" ] || NVCC=$(command -v nvcc || true)
[ -n "$NVCC" ] || { echo "nvcc not found"; exit 1; }

echo ">> Building CUDA self-test for sm_50"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
# CUDA 12.8+ warns on every sm_50 build that Maxwell is deprecated (it is
# still supported); silence it so real errors stand out.
"$NVCC" -O2 -arch=sm_50 -Wno-deprecated-gpu-targets \
    -o "$OUT/m10_cuda_selftest" "$HERE/tests/m10_cuda_selftest.cu"
echo ">> Running self-test (all GPUs)"
"$OUT/m10_cuda_selftest"
