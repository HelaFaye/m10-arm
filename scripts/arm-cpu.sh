#!/usr/bin/env bash
# arm-cpu.sh - what the host's ARM cores can actually execute, and how to build and run llama.cpp for them.
# Read-only. Works on any aarch64 Linux host (RK3588, Ampere, Grace, Raspberry Pi 5, ...).
#
#   ./scripts/arm-cpu.sh                              # features per core cluster, build arch, thread flags
#   ./scripts/arm-cpu.sh --check-build ~/llama.cpp/build
#                                                     # does that build use instructions this CPU lacks?
#
# Idea from Llaminar's native ARM port (src/v2/utils/ARMCPUFeatures.h): optional instructions are authenticated
# from what the kernel says the executing CPU has, never from compiler flags, and code compiled for a feature the
# machine lacks is refused before it runs. A llama.cpp built elsewhere (another board, a container image, CI) with
# i8mm, bf16 or SVE dies with SIGILL on an RK3588's A76/A55 cores; --check-build catches that first.
#
# Testing: CHECK_ROOT=/fake/root reads /proc and /sys under that directory (see tests/test-arm-cpu.sh).
# Exit status: 0 = fine, 1 = a build uses instructions this CPU lacks, 2 = not an ARM64 CPU.
set -u

R=${CHECK_ROOT:-}
CPUINFO=$R/proc/cpuinfo
BUILD=""
[ "${1:-}" = "--check-build" ] && BUILD=${2:?"usage: $0 --check-build BUILD_DIR"}

pass() { printf '  [PASS] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }

[ -r "$CPUINFO" ] || { echo "cannot read $CPUINFO"; exit 2; }

# CPU part (MIDR) -> core name, for the cores these boards and servers use
core_name() {
  case "$1" in
    0xd03) echo "Cortex-A53";; 0xd05) echo "Cortex-A55";; 0xd08) echo "Cortex-A72";; 0xd0b) echo "Cortex-A76";;
    0xd0c) echo "Neoverse-N1";; 0xd0d) echo "Cortex-A77";; 0xd41) echo "Cortex-A78";; 0xd44) echo "Cortex-X1";;
    0xd40) echo "Neoverse-V1";; 0xd46) echo "Cortex-A510";; 0xd47) echo "Cortex-A710";; 0xd48) echo "Cortex-X2";;
    0xd49) echo "Neoverse-N2";; 0xd4f) echo "Neoverse-V2";; 0xd80) echo "Cortex-A520";; 0xd81) echo "Cortex-A720";;
    0xd87) echo "Cortex-A725";; 0xd85) echo "Cortex-X925";;
    *) echo "part $1";;
  esac
}

# One line per core: "<cpu> <part> <capacity> <features...>"
CORES=$(awk -v root="$R" '
  /^processor[ \t]*:/ { if (cpu != "") print cpu, part, feats; cpu=$3; part="?"; feats="" }
  /^CPU part[ \t]*:/  { part=$4 }
  /^Features[ \t]*:/  { sub(/^Features[ \t]*:[ \t]*/, ""); feats=$0 }
  END { if (cpu != "") print cpu, part, feats }' "$CPUINFO" |
  while read -r cpu part feats; do
    cap=$(cat "$R/sys/devices/system/cpu/cpu$cpu/cpu_capacity" 2>/dev/null || echo 1024)
    echo "$cpu $part $cap $feats"
  done)
[ -n "$CORES" ] || { echo "no cores in $CPUINFO"; exit 2; }
echo "$CORES" | grep -qw asimd || { echo "not an ARM64 CPU with ASIMD (NEON)"; exit 2; }

has_all() {   # has_all FEATURE CORELINES: every listed core advertises FEATURE
  local f=$1 lines=$2
  printf '%s\n' "$lines" | awk -v f="$f" 'NF { ok=0; for (i=4;i<=NF;i++) if ($i==f) ok=1; if (!ok) bad=1 } END { exit bad }'
}

MAXCAP=$(echo "$CORES" | awk '{ if ($3 > m) m = $3 } END { print m }')
FAST=$(echo "$CORES" | awk -v m="$MAXCAP" '$3 == m')
NFAST=$(echo "$FAST" | wc -l)
NALL=$(echo "$CORES" | wc -l)

echo "== Cores"
echo "$CORES" | awk '{ print $2, $3 }' | sort | uniq -c | while read -r n part cap; do
  printf '  %s x %s (capacity %s)\n' "$n" "$(core_name "$part")" "$cap"
done

# Kernel feature names (/proc/cpuinfo) -> what llama.cpp and compilers call them
FEATS="asimddp:dotprod asimdhp:fp16 bf16:bf16 i8mm:i8mm sve:sve sve2:sve2"
echo
echo "== Instructions (fast cores / all cores)"
for pair in $FEATS; do
  k=${pair%%:*} n=${pair##*:}
  f="no"; a="no"
  has_all "$k" "$FAST" && f="yes"
  has_all "$k" "$CORES" && a="yes"
  printf '  %-8s %-4s / %s\n' "$n" "$f" "$a"
done

# The portable architecture for a build that runs on every core of this machine
ARCH="armv8-a"
EXT=""
if has_all asimddp "$CORES"; then ARCH="armv8.2-a"; EXT="$EXT+dotprod"; fi
if has_all asimdhp "$CORES"; then [ "$ARCH" = armv8-a ] && ARCH="armv8.2-a"; EXT="$EXT+fp16"; fi
has_all i8mm "$CORES" && EXT="$EXT+i8mm"
has_all bf16 "$CORES" && EXT="$EXT+bf16"
echo
echo "== Building llama.cpp for this machine"
echo "  On this machine, -DGGML_NATIVE=ON (the default) is right."
echo "  Elsewhere (a container image, another board, CI), build portably for it:"
echo "    -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=$ARCH$EXT"

# Threads: pin to the fast cores with llama.cpp's own affinity flags
echo
echo "== Running llama.cpp"
if [ "$NFAST" -lt "$NALL" ]; then
  MASK=$(echo "$FAST" | awk '{ m += 2 ^ $1 } END { printf "0x%X", m }')
  echo "  Big.LITTLE: keep llama.cpp on the $NFAST fast cores (prompt reading and sampling run there):"
  echo "    -t $NFAST -tb $NFAST -C $MASK -Cb $MASK --cpu-strict 1"
  echo "  (llama.cpp pins each thread itself; this replaces taskset, and the slow cores stay free for the GPU driver)"
else
  echo "  All cores are alike: -t $NALL (add -C/--cpu-strict only to share the machine)"
fi

# --check-build: does a build use instructions this CPU lacks? (Llaminar's requireEnvelope)
[ -z "$BUILD" ] && exit 0
echo
echo "== Build check: $BUILD"
CACHE=$BUILD/CMakeCache.txt
[ -r "$CACHE" ] || { fail "no CMakeCache.txt in $BUILD"; exit 1; }
NATIVE=$(sed -n 's/^GGML_NATIVE:[A-Z]*=//p' "$CACHE")
BARCH=$(sed -n 's/^GGML_CPU_ARM_ARCH:[A-Z]*=//p' "$CACHE")
if [ -z "$BARCH" ]; then
  if [ "$NATIVE" = ON ]; then
    warn "built with GGML_NATIVE=ON: right only if it was built on this machine (or one with the same cores)"
  else
    pass "no -march extensions requested (baseline ARMv8 NEON)"
  fi
  exit 0
fi
echo "  built for: $BARCH"
need=""
case "$BARCH" in
  armv8.[4-9]-a*|armv9*) need="$need asimddp";;      # dot product is mandatory from ARMv8.4
esac
case "$BARCH" in
  armv8.[6-9]-a*|armv9.[1-9]*) need="$need i8mm bf16";;   # and Int8 matmul and BF16 from ARMv8.6
esac
case "$BARCH" in armv9*) need="$need sve sve2";; esac
for ext in $(echo "$BARCH" | tr '+' ' '); do
  case "$ext" in
    dotprod) need="$need asimddp";; fp16) need="$need asimdhp";; i8mm) need="$need i8mm";;
    bf16) need="$need bf16";; sve) need="$need sve";; sve2) need="$need sve2";;
  esac
done
BAD=0
for k in $(echo "$need" | tr ' ' '\n' | sort -u); do
  if has_all "$k" "$CORES"; then
    pass "$k: every core has it"
  elif has_all "$k" "$FAST"; then
    warn "$k: only the fast cores have it; pin llama.cpp to them (-C/--cpu-strict above) or it can die with SIGILL"
  else
    fail "$k: this CPU lacks it; the build will die with SIGILL. Rebuild with -DGGML_CPU_ARM_ARCH=$ARCH$EXT"
    BAD=1
  fi
done
exit $BAD
