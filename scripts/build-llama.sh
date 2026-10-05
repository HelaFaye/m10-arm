#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Build llama.cpp for the Tesla M10 (Maxwell, sm_50) with CUDA and/or Vulkan,
# then check every GPU's results against the CPU with ggml's test-backend-ops.
# Wrong results there are what a cache-coherency bug looks like.
#
# Needs the patched driver (scripts/install.sh). CUDA needs the 12.9 toolkit
# (scripts/setup-cuda.sh); Vulkan needs the driver installed --with-vulkan.
#
# *** UNTESTED WORK IN PROGRESS. ***
#
#   scripts/build-llama.sh [--cuda] [--vulkan] [--full-test | --no-test] [dir]
#
# Default: --cuda, a quick test of the ops LLM inference relies on most, and
# the source in ./llama.cpp. Set LLAMA_COMMIT to build a different commit, and
# EXPECT_GPUS if fewer than the M10's four GPUs should be tested.
set -eu

LLAMA_REPO=https://github.com/ggml-org/llama.cpp
LLAMA_COMMIT=${LLAMA_COMMIT:-889edf43ddae0cfe9a4564a882764dc879759870}
CUDA_HOME=${CUDA_HOME:-/usr/local/cuda-12.9}
EXPECT_GPUS=${EXPECT_GPUS:-4}   # the M10 is four GPUs
QUICK_OPS=MUL_MAT,MUL_MAT_ID,GET_ROWS,CPY,ADD,MUL,RMS_NORM,ROPE,SOFT_MAX,FLASH_ATTN_EXT

usage() { echo "usage: $0 [--cuda] [--vulkan] [--full-test | --no-test] [dir]"; }

CUDA=0 VULKAN=0 TEST=quick
while [ $# -gt 0 ]; do
    case $1 in
        --cuda) CUDA=1 ;;
        --vulkan) VULKAN=1 ;;
        --full-test) TEST=full ;;
        --no-test) TEST=none ;;
        -h|--help) usage; exit 0 ;;
        -*) usage; exit 2 ;;
        *) break ;;
    esac
    shift
done
[ "$CUDA" = 1 ] || [ "$VULKAN" = 1 ] || CUDA=1
DIR=${1:-$PWD/llama.cpp}
JOBS=${JOBS:-$(nproc)}

for t in git cmake; do
    command -v $t >/dev/null || { echo "$t is required (apt install git cmake build-essential)"; exit 1; }
done
if [ "$CUDA" = 1 ] && [ ! -x "$CUDA_HOME/bin/nvcc" ]; then
    echo "nvcc not found in $CUDA_HOME - run scripts/setup-cuda.sh first (or set CUDA_HOME)"
    exit 1
fi
if [ "$VULKAN" = 1 ]; then
    if ! command -v glslc >/dev/null || [ ! -e /usr/include/vulkan/vulkan.h ] ||
       [ ! -d /usr/include/spirv ]; then
        echo "Vulkan build needs: sudo apt install libvulkan-dev glslc spirv-headers"
        exit 1
    fi
fi

# Fetch exactly the pinned commit
if [ ! -d "$DIR/.git" ]; then
    echo ">> Fetching llama.cpp $LLAMA_COMMIT -> $DIR"
    git init -q "$DIR"
    git -C "$DIR" remote add origin "$LLAMA_REPO"
fi
if [ "$(git -C "$DIR" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$LLAMA_COMMIT" ]; then
    git -C "$DIR" fetch -q --depth 1 origin "$LLAMA_COMMIT"
    git -C "$DIR" checkout -q --detach FETCH_HEAD
fi

build() {   # build <name> <cmake args...>
    name=$1; shift
    echo ">> Building llama.cpp ($name) in $DIR/build-$name"
    cmake -S "$DIR" -B "$DIR/build-$name" -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BUILD_TESTS=ON "$@"
    cmake --build "$DIR/build-$name" -j "$JOBS"
}

# test-backend-ops skips the CPU and reports success when it finds no GPU at
# all, so also count the GPU backends it actually tested.
run_tests() {   # run_tests <name>
    [ "$TEST" = none ] && return 0
    log=$DIR/build-$1/test-backend-ops.log
    echo ">> Checking $1 results against the CPU on every GPU ($TEST test, log: $log)"
    rc=0
    if [ "$TEST" = quick ]; then
        "$DIR/build-$1/bin/test-backend-ops" test -o "$QUICK_OPS" > "$log" 2>&1 || rc=$?
    else
        "$DIR/build-$1/bin/test-backend-ops" test > "$log" 2>&1 || rc=$?
    fi
    grep -E '^Backend |passed|FAIL|Skipping' "$log" | tail -40
    n=$(grep -cE '^Backend [0-9]+/[0-9]+: (CUDA|Vulkan)[0-9]' "$log" || true)
    echo ">> GPUs tested: $n (expected $EXPECT_GPUS), test-backend-ops exit code $rc"
    if [ "$n" -lt "$EXPECT_GPUS" ]; then
        echo "!! $1: only $n GPU(s) found. Check nvidia-smi (CUDA) or scripts/check-vulkan.sh (Vulkan)."
        return 1
    fi
    if [ "$rc" != 0 ]; then
        echo "!! $1: GPU results differ from the CPU (FAIL lines above)."
        return 1
    fi
}

FAILED=""
if [ "$CUDA" = 1 ]; then
    build cuda -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=50 \
        -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc"
    run_tests cuda || FAILED="$FAILED cuda"
fi
if [ "$VULKAN" = 1 ]; then
    build vulkan -DGGML_VULKAN=ON
    run_tests vulkan || FAILED="$FAILED vulkan"
fi

if [ -n "$FAILED" ]; then
    echo "!! Checks failed for:$FAILED"
    echo "   Please open an issue with the output above and 'sudo dmesg | grep -E \"NVRM|nvidia\"'."
    exit 1
fi
echo ">> Done. Binaries are in $DIR/build-*/bin (llama-cli, llama-server, llama-bench, ...)"
echo "   Spread a model over the M10's four GPUs:  -ngl 99 --split-mode layer"
