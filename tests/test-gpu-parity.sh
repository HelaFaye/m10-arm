#!/usr/bin/env bash
# Exercises scripts/gpu-parity.sh with a stand-in test-backend-ops: a GPU that matches, one that doesn't, and a
# CPU-only build (which test-backend-ops itself reports as passing). No GPU needed.
#   ./tests/test-gpu-parity.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../scripts/gpu-parity.sh
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
T_PASS=0; T_FAIL=0

mock() {   # mock <dir> <exit> <output>
  mkdir -p "$1"
  printf '#!/bin/sh\necho "$*" > "%s/args"\ncat <<"OUT"\n%s\nOUT\nexit %s\n' "$1" "$3" "$2" > "$1/test-backend-ops"
  chmod +x "$1/test-backend-ops"
}
run() {   # run <name> <want-exit> <bin> <script args...> -- <patterns...>
  local name=$1 want=$2 bin=$3; shift 3
  local args=() pats=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  pats=("$@")
  OUT=$(cd "$WORK" && LLAMA_BIN=$bin PARITY_LOG=$WORK/p.log bash "$SCRIPT" "${args[@]}" 2>&1); RC=$?
  local ok=1
  [ "$RC" -eq "$want" ] || { echo "    exit $RC, wanted $want"; ok=0; }
  for p in "${pats[@]}"; do grep -qE -- "$p" <<<"$OUT"$'\n'"$(cat "$bin/args" 2>/dev/null)" || { echo "    missing: $p"; ok=0; }; done
  if [ $ok -eq 1 ]; then echo "ok   - $name"; T_PASS=$((T_PASS+1)); else echo "FAIL - $name"; printf '%s\n' "$OUT"; T_FAIL=$((T_FAIL+1)); fi
}

mock "$WORK/good" 0 "Backend 1/2: CUDA0
  Device description: Tesla M10
  MUL_MAT(type_a=q4_0,type_b=f32,m=16,n=1,k=256): OK
  18/18 tests passed
  Backend CUDA0: OK
Backend 2/2: CPU
  Skipping CPU backend
2/2 backends passed
OK"
run "a GPU that matches the CPU" 0 "$WORK/good" -- "Every GPU backend matched" "test -o MUL_MAT,MUL_MAT_ID"

mock "$WORK/bad" 1 "Backend 1/2: CUDA3
  MUL_MAT(type_a=q4_K,type_b=f32,m=16,n=1,k=256): [MUL_MAT] NMSE = 0.53 > 0.0005 FAIL
  17/18 tests passed
  Backend CUDA3: FAIL
Backend 2/2: CPU
  Skipping CPU backend
1/2 backends passed
FAIL"
run "a GPU that differs: names the failing op, points at coherency" 1 "$WORK/bad" -- \
    "MISMATCH" "NMSE = 0.53 .* FAIL" "arm_force_uncached"

mock "$WORK/cpu" 0 "Backend 1/1: CPU
  Skipping CPU backend
1/1 backends passed
OK"
run "CPU only: nothing was compared" 3 "$WORK/cpu" -- "NO GPU BACKEND"

run "--all and -b pass through" 0 "$WORK/good" --all -b CUDA0 -- "^test -b CUDA0$"

echo; echo "$T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ]
