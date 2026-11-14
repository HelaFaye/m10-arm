#!/usr/bin/env bash
# shellcheck disable=SC2001
# Exercises scripts/arm-cpu.sh against fake /proc/cpuinfo and cpu_capacity trees and fake llama.cpp builds.
# No ARM hardware needed.
#   ./tests/test-arm-cpu.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../scripts/arm-cpu.sh
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
T_PASS=0; T_FAIL=0

# What RK3588's Cortex-A55 and Cortex-A76 cores report: dotprod and fp16, no i8mm, bf16 or SVE.
V82="fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp"

# mkcpus <root> "<part> <capacity> <features>"... (one argument per core)
mkcpus() {
  local r=$1; shift; local i=0
  mkdir -p "$r/proc"; : > "$r/proc/cpuinfo"
  for spec in "$@"; do
    read -r part cap feats <<<"$spec"
    printf 'processor\t: %d\nBogoMIPS\t: 48.00\nFeatures\t: %s\nCPU implementer\t: 0x41\nCPU part\t: %s\n\n' \
      "$i" "$feats" "$part" >> "$r/proc/cpuinfo"
    mkdir -p "$r/sys/devices/system/cpu/cpu$i"
    echo "$cap" > "$r/sys/devices/system/cpu/cpu$i/cpu_capacity"
    i=$((i+1))
  done
}
mkbuild() {   # mkbuild <dir> <GGML_NATIVE> [GGML_CPU_ARM_ARCH]
  mkdir -p "$1"
  printf 'GGML_NATIVE:BOOL=%s\n' "$2" > "$1/CMakeCache.txt"
  [ -n "${3:-}" ] && printf 'GGML_CPU_ARM_ARCH:STRING=%s\n' "$3" >> "$1/CMakeCache.txt"
}
run() {   # run <name> <want-exit> <root> <args...> -- <patterns...>
  local name=$1 want=$2 root=$3; shift 3
  local args=() pats=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  pats=("$@")
  OUT=$(CHECK_ROOT=$root bash "$SCRIPT" "${args[@]}" 2>&1); RC=$?
  local ok=1
  [ "$RC" -eq "$want" ] || { echo "    exit $RC, wanted $want"; ok=0; }
  for p in "${pats[@]}"; do grep -qE -- "$p" <<<"$OUT" || { echo "    missing: $p"; ok=0; }; done
  if [ $ok -eq 1 ]; then echo "ok   - $name"; T_PASS=$((T_PASS+1))
  else echo "FAIL - $name"; echo "$OUT" | sed 's/^/      | /'; T_FAIL=$((T_FAIL+1)); fi
}

RK=$WORK/rk3588
mkcpus "$RK" "0xd05 414 $V82" "0xd05 414 $V82" "0xd05 414 $V82" "0xd05 414 $V82" \
             "0xd0b 1024 $V82" "0xd0b 1024 $V82" "0xd0b 1024 $V82" "0xd0b 1024 $V82"

run "RK3588: clusters, arch, thread flags" 0 "$RK" -- '4 x Cortex-A55' '4 x Cortex-A76' \
    'dotprod +yes +/ yes' 'i8mm +no' 'GGML_CPU_ARM_ARCH=armv8.2-a\+dotprod\+fp16' \
    '-t 4 -tb 4 -C 0xF0 -Cb 0xF0 --cpu-strict 1' 'cpu-threads-bench.sh MODEL.gguf'

mkbuild "$WORK/b-ok" OFF "armv8.2-a+dotprod+fp16"
run "portable build for this board passes" 0 "$RK" --check-build "$WORK/b-ok" -- 'PASS\] asimddp' 'PASS\] asimdhp'

mkbuild "$WORK/b-i8mm" OFF "armv8.2-a+dotprod+i8mm"
run "a build with i8mm fails on RK3588" 1 "$RK" --check-build "$WORK/b-i8mm" -- 'FAIL\] i8mm.*SIGILL'

mkbuild "$WORK/b-v86" OFF "armv8.6-a"
run "ARMv8.6 implies i8mm and bf16" 1 "$RK" --check-build "$WORK/b-v86" -- 'FAIL\] bf16' 'FAIL\] i8mm'

mkbuild "$WORK/b-native" ON
run "a native build is a warning, not a failure" 0 "$RK" --check-build "$WORK/b-native" -- 'WARN\] built with GGML_NATIVE=ON'

run "a missing build fails" 1 "$RK" --check-build "$WORK/nope" -- 'FAIL\] no CMakeCache'

# A hypothetical mixed machine: only the fast cores have i8mm, so a build using it must be pinned to them
MIX=$WORK/mixed
mkcpus "$MIX" "0xd80 300 $V82" "0xd80 300 $V82" "0xd81 1024 $V82 i8mm bf16" "0xd81 1024 $V82 i8mm bf16"
run "only the fast cores have the feature: warn to pin" 0 "$MIX" --check-build "$WORK/b-i8mm" -- \
    'WARN\] i8mm: only the fast cores' 'GGML_CPU_ARM_ARCH=armv8.2-a\+dotprod\+fp16$'

# A server whose cores are all alike, with i8mm and bf16
SRV=$WORK/server
mkcpus "$SRV" "0xd4f 1024 $V82 i8mm bf16 sve sve2" "0xd4f 1024 $V82 i8mm bf16 sve sve2"
run "uniform server: no pinning needed, i8mm and bf16 in the arch" 0 "$SRV" -- \
    'All cores are alike: -t 2' 'armv8.2-a\+dotprod\+fp16\+i8mm\+bf16' '2 x Neoverse-V2'

X86=$WORK/x86
mkdir -p "$X86/proc"; printf 'processor\t: 0\nflags\t\t: fpu sse sse2 avx2\n\n' > "$X86/proc/cpuinfo"
run "not ARM64" 2 "$X86" -- 'not an ARM64 CPU'

echo; echo "$T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ]
