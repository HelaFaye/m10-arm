#!/usr/bin/env bash
# gpu-parity.sh - does the GPU compute the same numbers as the CPU? Runs llama.cpp's test-backend-ops, which
# executes each operation on the GPU backend and compares the result with the CPU backend.
#
#   ./scripts/gpu-parity.sh                         # the operations inference uses, on every GPU llama.cpp sees
#   ./scripts/gpu-parity.sh --all                   # every operation (slow)
#   ./scripts/gpu-parity.sh -b CUDA2                # one of the M10's four GPUs
#   LLAMA_BIN=~/llama.cpp/build/bin ./scripts/gpu-parity.sh
#
# Why this matters here: RK3588's PCIe is not cache-coherent, and the stock NVIDIA driver assumes it is. If the
# patched module isn't the one loaded, or its uncached mappings are switched off (arm_force_uncached=0), the GPUs
# read stale data. That gives wrong numbers rather than a crash. Each of the M10's four GPUs is its own CUDA
# backend (CUDA0..CUDA3), and each is checked. Llaminar's ARM port treats such parity checks
# as the gate every kernel passes before it counts; this is the same discipline with llama.cpp's own harness.
#
# Exit status: test-backend-ops' own (0 = every backend matched the CPU), or 3 when no GPU backend was found.
# The full log is kept.
set -uo pipefail

ALL=0
BACKEND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift;;
    -b) BACKEND=${2:?"-b needs a backend name, e.g. CUDA0"}; shift 2;;
    -h|--help) sed -n '2,17p' "$0"; exit 0;;
    *) echo "unknown argument: $1 (see --help)"; exit 2;;
  esac
done

BIN=${LLAMA_BIN:-}
if [ -z "$BIN" ]; then
  for d in "$HOME/llama.cpp/build/bin" "$HOME/llama.cpp/build-cuda/bin"; do
    [ -x "$d/test-backend-ops" ] && { BIN=$d; break; }
  done
fi
TBO=$BIN/test-backend-ops
[ -x "$TBO" ] || { echo "no test-backend-ops found (set LLAMA_BIN to llama.cpp's build/bin; a default llama.cpp build makes it)"; exit 2; }

# The operations a transformer's forward pass uses. Quantized matrix multiplication is where a stale read hides.
OPS="MUL_MAT,MUL_MAT_ID,ADD,MUL,RMS_NORM,NORM,ROPE,SOFT_MAX,FLASH_ATTN_EXT,GET_ROWS,CPY,CONT,SCALE,GLU,UNARY,ARGSORT"
ARGS=()
[ "$ALL" -eq 1 ] || ARGS+=(-o "$OPS")
[ -n "$BACKEND" ] && ARGS+=(-b "$BACKEND")

LOG=${PARITY_LOG:-gpu-parity-$(date +%Y%m%d-%H%M%S).log}
echo "running: $TBO test ${ARGS[*]}  (log: $LOG)"
"$TBO" test "${ARGS[@]}" 2>&1 | tee "$LOG" | grep -E "^Backend|OK$|FAIL|passed|Skipping" | grep -vE "^\s+[A-Z_]+\(.*\): OK$"
RC=${PIPESTATUS[0]}
echo
# With no GPU backend, test-backend-ops skips the CPU and still reports success: that tested nothing.
if ! grep -E "^Backend [0-9]+/[0-9]+: " "$LOG" | grep -qv ": CPU$"; then
  echo "NO GPU BACKEND: llama.cpp saw only the CPU, so nothing was compared. Build with -DGGML_CUDA=ON"
  echo "(README: Using CUDA) and check that nvidia-smi lists the four GPUs."
  exit 3
fi
if [ "$RC" -eq 0 ]; then
  echo "Every GPU backend matched the CPU on these operations."
else
  echo "MISMATCH: at least one operation's GPU result differs from the CPU (failing cases: grep FAIL $LOG)."
  echo "On RK3588, check that the patched module is loaded with uncached system memory first:"
  echo "  sudo dmesg | grep 'sysmem forced uncached'   and   cat /sys/module/nvidia/parameters/arm_force_uncached"
fi
exit "$RC"
