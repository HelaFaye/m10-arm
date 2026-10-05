#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Build PyTorch from source for the Tesla M10 (Maxwell, sm_50) on aarch64,
# install it into a virtualenv and run tests/torch_selftest.py.
#
# Why from source: PyTorch's aarch64 CUDA wheels are built only for newer GPUs
# (its build scripts explicitly drop sm_50 on aarch64). Upstream still
# compiles sm_50 for its x86_64 CUDA 12.6 wheels, up to at least v2.14.1, so
# the kernels themselves still build for Maxwell.
#
# Needs the patched driver (scripts/install.sh) and CUDA 12.9
# (scripts/setup-cuda.sh). Expect many hours on an RK3588 and lots of memory:
# MAX_JOBS is derived from RAM + swap; adding swap helps.
#
# *** UNTESTED WORK IN PROGRESS. ***
#
#   scripts/build-torch.sh [source-dir]          (default: ./pytorch)
#
# Environment:
#   TORCH_VERSION  git tag to build (default v2.14.1)
#   VENV           virtualenv to create/use (default ./torch-venv)
#   MAX_JOBS       parallel compile jobs (default: about one per 3 GB of RAM+swap)
#   WITH_CUDNN     auto (default) | 1 | 0 - see the cuDNN section below
#   WITH_NCCL      0 (default) | 1 - multi-GPU collectives; see below
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
TORCH_VERSION=${TORCH_VERSION:-v2.14.1}
CUDA_HOME=${CUDA_HOME:-/usr/local/cuda-12.9}
SRC=${1:-$PWD/pytorch}
VENV=${VENV:-$PWD/torch-venv}
WITH_CUDNN=${WITH_CUDNN:-auto}
WITH_NCCL=${WITH_NCCL:-0}
# The cuDNN upstream pairs with its sm_50-capable CUDA 12.6 wheels; its CUDA
# 12.9 builds use a newer cuDNN, which suggests later releases dropped Maxwell.
CUDNN_VERSION=9.10.2.21

[ "$(uname -m)" = aarch64 ] || echo "!! Not aarch64 - this script targets the Orange Pi 5 Plus."
[ -x "$CUDA_HOME/bin/nvcc" ] || { echo "nvcc not found in $CUDA_HOME - run scripts/setup-cuda.sh first"; exit 1; }
for t in git gcc g++ python3; do
    command -v $t >/dev/null || { echo "$t is required (sudo apt install git build-essential python3-dev python3-venv)"; exit 1; }
done
python3 -c 'import venv, ensurepip' 2>/dev/null || { echo "sudo apt install python3-venv python3-dev"; exit 1; }

# ~1 job per 3 GB of RAM + swap: nvcc on PyTorch's CUDA files needs 2-3 GB each.
if [ -z "${MAX_JOBS:-}" ]; then
    mem_gb=$(awk '/^(MemTotal|SwapTotal):/ { kb += $2 } END { print int(kb / 1048576) }' /proc/meminfo)
    MAX_JOBS=$((mem_gb / 3))
    [ "$MAX_JOBS" -ge 1 ] || MAX_JOBS=1
    [ "$MAX_JOBS" -le "$(nproc)" ] || MAX_JOBS=$(nproc)
fi
free_gb=$(df -Pk "$(dirname "$SRC")" | awk 'NR == 2 { print int($4 / 1048576) }')
[ "$free_gb" -ge 40 ] || echo "!! Only ${free_gb} GB free here; a PyTorch build needs about 40 GB."

# --- cuDNN: optional, faster convolutions (vision models). Only the pinned
# version is used automatically, because newer cuDNN may not support Maxwell.
# NVIDIA's sbsa apt repo (added by setup-cuda.sh) has it; the dev package
# requires the runtime and headers packages at exactly the same version, so
# all three must be named, and held so an upgrade can't replace them.
CUDNN_PKGS="libcudnn9-cuda-12 libcudnn9-headers-cuda-12 libcudnn9-dev-cuda-12"
CUDNN_APT=""
for p in $CUDNN_PKGS; do CUDNN_APT="$CUDNN_APT $p=$CUDNN_VERSION-1"; done
cudnn_have=$(dpkg-query -W -f='${Version}' libcudnn9-dev-cuda-12 2>/dev/null || true)
case $WITH_CUDNN in
    1) USE_CUDNN=1 ;;
    0) USE_CUDNN=0 ;;
    auto)
        case $cudnn_have in
            "$CUDNN_VERSION"*) USE_CUDNN=1 ;;
            "") USE_CUDNN=0
                echo "!! cuDNN not installed; building without it (convolutions use slower native kernels)."
                echo "   To use it: sudo apt install$CUDNN_APT && sudo apt-mark hold $CUDNN_PKGS" ;;
            *)  USE_CUDNN=0
                echo "!! cuDNN $cudnn_have is installed, not $CUDNN_VERSION; it may not support Maxwell,"
                echo "   so building without cuDNN. WITH_CUDNN=1 uses it anyway." ;;
        esac ;;
    *) echo "WITH_CUDNN must be auto, 1 or 0"; exit 2 ;;
esac
# Tell CMake exactly where the headers package put cudnn.h. For the sbsa
# 9.10.2.21-1 package that's /usr/include/aarch64-linux-gnu, where cudnn.h
# and cudnn_version.h are links to the *_v9.h headers.
if [ "$USE_CUDNN" = 1 ]; then
    cudnn_h=$(dpkg -L libcudnn9-headers-cuda-12 2>/dev/null | grep '/cudnn\.h$' | head -1 || true)
    if [ -n "$cudnn_h" ]; then
        CUDNN_INCLUDE_DIR=$(dirname "$cudnn_h")
        export CUDNN_INCLUDE_DIR
    fi
fi

# --- Source at the pinned tag
if [ ! -d "$SRC/.git" ]; then
    echo ">> Fetching PyTorch $TORCH_VERSION -> $SRC"
    git clone --depth 1 --branch "$TORCH_VERSION" --recurse-submodules \
        --shallow-submodules --jobs 8 https://github.com/pytorch/pytorch "$SRC"
fi
have=$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)
[ "$have" = "$TORCH_VERSION" ] || {
    echo "$SRC is at '${have:-unknown}', not $TORCH_VERSION. Use another directory or remove it."
    exit 1; }

# --- Virtualenv with the build requirements
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install -q --upgrade pip
"$VENV/bin/python" -m pip install -q -r "$SRC/requirements-build.txt"

# --- Build configuration. USE_*/BUILD_* and TORCH_CUDA_ARCH_LIST reach CMake
# through cmake/EnvVarForwarding.cmake.
export VIRTUAL_ENV="$VENV" PATH="$VENV/bin:$CUDA_HOME/bin:$PATH"
export CMAKE_PREFIX_PATH="$VENV${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export CUDA_HOME MAX_JOBS USE_CUDNN
export USE_CUDA=1
export TORCH_CUDA_ARCH_LIST=5.0
# CUDA 12.8+ warns that Maxwell is deprecated (but still supported)
export TORCH_NVCC_FLAGS="-Wno-deprecated-gpu-targets"
# Features that need newer GPUs, or only add build time here:
#  flash / memory-efficient attention: scaled_dot_product_attention falls
#  back to its math kernel; NVSHMEM, cuSPARSELt, cuDSS, cuFile, MSLK: not
#  usable or not needed on the M10.
export USE_FLASH_ATTENTION=0 USE_MEM_EFF_ATTENTION=0 USE_NVSHMEM=0 \
       USE_CUSPARSELT=0 USE_CUDSS=0 USE_CUFILE=0 USE_MSLK=0 BUILD_TEST=0
# NCCL (fast multi-GPU collectives) is off by default: it's a long extra
# build and its Maxwell support is unverified. Without it, multi-GPU code
# still works through torch.distributed's gloo backend or model parallelism.
if [ "$WITH_NCCL" = 1 ]; then export USE_NCCL=1 USE_SYSTEM_NCCL=0; else export USE_NCCL=0; fi

echo ">> Building PyTorch $TORCH_VERSION for sm_50 with MAX_JOBS=$MAX_JOBS, cuDNN=$USE_CUDNN, NCCL=$WITH_NCCL"
echo "   (this takes hours; the build directory is $SRC/build)"
cd "$SRC"
"$VENV/bin/python" -m pip wheel . --no-build-isolation --no-deps -w dist -v

wheel=$(ls -t dist/torch-*.whl | head -1)
echo ">> Installing $wheel into $VENV"
"$VENV/bin/python" -m pip install --force-reinstall --no-deps "$wheel"
"$VENV/bin/python" -m pip install "$wheel"   # its runtime dependencies

echo ">> Running the PyTorch self-test"
cd "$HERE"
"$VENV/bin/python" tests/torch_selftest.py
echo ">> Done. Use it with: . $VENV/bin/activate"
