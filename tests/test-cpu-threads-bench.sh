#!/usr/bin/env bash
# shellcheck disable=SC2001
# Exercises scripts/cpu-threads-bench.sh with a stand-in llama-bench and fake /proc/cpuinfo trees.
# No ARM hardware or model needed.
#   ./tests/test-cpu-threads-bench.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../scripts/cpu-threads-bench.sh
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
T_PASS=0; T_FAIL=0

mkcpus() {   # mkcpus <root> <capacity>...
  local r=$1; shift; local i=0
  mkdir -p "$r/proc"; : > "$r/proc/cpuinfo"
  for cap in "$@"; do
    printf 'processor\t: %d\nFeatures\t: fp asimd asimddp\n\n' "$i" >> "$r/proc/cpuinfo"
    mkdir -p "$r/sys/devices/system/cpu/cpu$i"; echo "$cap" > "$r/sys/devices/system/cpu/cpu$i/cpu_capacity"
    i=$((i+1))
  done
}

# Stand-in llama-bench: logs its arguments and environment, and prints jsonl whose speeds depend on them.
# Generation is fastest with every core pinned plus the longer spin; prompt processing with every core pinned.
mkbench() {   # mkbench <dir> <GGML_OPENMP ON|OFF>
  mkdir -p "$1/bin"
  printf 'GGML_OPENMP:BOOL=%s\n' "$2" > "$1/CMakeCache.txt"
  cat > "$1/bin/llama-bench" <<'EOF'
#!/usr/bin/env bash
echo "args: $* | spin=${GOMP_SPINCOUNT:-}" >> "$(dirname "$0")/calls.log"
t=0; strict=0; poll=0
while [ $# -gt 0 ]; do
  case "$1" in -t) t=$2; shift;; --cpu-strict) strict=$2; shift;; --poll) poll=$2; shift;; esac; shift
done
pp=$((t * 10 + strict * 5)); tg=$((t + strict * 2))
{ [ -n "${GOMP_SPINCOUNT:-}" ] || [ "$poll" = 100 ]; } && tg=$((tg + 3))
echo "{\"build_commit\": \"x\", \"n_prompt\": 512, \"n_gen\": 0, \"avg_ts\": $pp.000000, \"stddev_ts\": 0.1}"
echo "{\"build_commit\": \"x\", \"n_prompt\": 0, \"n_gen\": 128, \"avg_ts\": $tg.500000, \"stddev_ts\": 0.1}"
EOF
  chmod +x "$1/bin/llama-bench"
}

check() {   # check <name> <want-exit> <patterns...>   (uses $OUT and $RC)
  local name=$1 want=$2; shift 2; local ok=1
  [ "$RC" -eq "$want" ] || { echo "    exit $RC, wanted $want"; ok=0; }
  for p in "$@"; do grep -qE -- "$p" <<<"$OUT" || { echo "    missing: $p"; ok=0; }; done
  if [ $ok -eq 1 ]; then echo "ok   - $name"; T_PASS=$((T_PASS+1))
  else echo "FAIL - $name"; echo "$OUT" | sed 's/^/      | /'; T_FAIL=$((T_FAIL+1)); fi
}

MODEL=$WORK/model.gguf; : > "$MODEL"
RK=$WORK/rk3588; mkcpus "$RK" 414 414 414 414 1024 1024 1024 1024
mkbench "$WORK/omp" ON
OUT=$(CHECK_ROOT=$RK LLAMA_BIN=$WORK/omp/bin ROUNDS=2 REPS=1 bash "$SCRIPT" "$MODEL" -- -ngl 99 2>&1); RC=$?
check "RK3588: six setups, averaged, fastest named" 0 \
  '8 cores, 4 fast; 6 setups x 2 rounds' 'GOMP_SPINCOUNT=3000000 \(OpenMP build\)' \
  'fast +45\.00 +6\.50' 'all +85\.00 +\+88\.9% +10\.50 +\+61\.5%' 'all\+spin +85\.00 +\+88\.9% +13\.50 +\+107\.7%' \
  'all-free +80\.00' 'fastest prompt processing: all$' 'fastest generation: all\+spin' '-C 0xF0 --cpu-strict 1'
LOG=$WORK/omp/bin/calls.log
OUT=$(cat "$LOG"); RC=0
check "llama-bench calls: masks, extra args, spin only on +spin" 0 \
  '-t 4 -r 1 -o jsonl -C 0xF0 --cpu-strict 1 -ngl 99 \| spin=$' '-t 8 -r 1 -o jsonl -C 0xFF --cpu-strict 1 -ngl 99 \| spin=3000000' \
  '-t 8 -r 1 -o jsonl -ngl 99 \| spin=$'
OUT=$(sed -n '1p;6p;7p;12p' "$LOG"); RC=0
check "second round runs in reverse (A B B A)" 0 '^args: .*-t 4 .*spin=$' '^args: -m .* -t 8 -r 1 -o jsonl -ngl 99 \| spin=3000000' \
  'spin=$'
[ "$(sed -n '6p' "$LOG")" = "$(sed -n '7p' "$LOG")" ] || { echo "FAIL - round 2 does not start where round 1 ended"; T_FAIL=$((T_FAIL+1)); }

mkbench "$WORK/noomp" OFF
OUT=$(CHECK_ROOT=$RK LLAMA_BIN=$WORK/noomp/bin ROUNDS=1 REPS=1 bash "$SCRIPT" "$MODEL" 2>&1); RC=$?
check "build without OpenMP uses --poll 100" 0 '--poll 100 \(build without OpenMP\)' 'fastest generation: all\+spin'
OUT=$(cat "$WORK/noomp/bin/calls.log"); RC=0
check "  ... and never sets GOMP_SPINCOUNT" 0 '--poll 100 \| spin=$'
grep -q 'spin=3' "$WORK/noomp/bin/calls.log" && { echo "FAIL - GOMP_SPINCOUNT set for a non-OpenMP build"; T_FAIL=$((T_FAIL+1)); }

SRV=$WORK/server; mkcpus "$SRV" 1024 1024 1024 1024
rm -f "$LOG"
OUT=$(CHECK_ROOT=$SRV LLAMA_BIN=$WORK/omp/bin ROUNDS=1 REPS=1 bash "$SCRIPT" "$MODEL" 2>&1); RC=$?
check "alike cores: no fast-only setup" 0 '4 cores, 4 fast; 4 setups' 'change against all\)'
grep -q '^   fast ' <<<"$OUT" && { echo "FAIL - fast setup on a machine with alike cores"; T_FAIL=$((T_FAIL+1)); }

OUT=$(CHECK_ROOT=$RK LLAMA_BIN=$WORK/none bash "$SCRIPT" "$MODEL" 2>&1); RC=$?
check "no llama-bench: exit 2" 2 'no llama-bench found'
OUT=$(bash "$SCRIPT" 2>&1); RC=$?
check "no model: usage, exit 2" 2 'usage:'

printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/omp/bin/llama-bench"
OUT=$(CHECK_ROOT=$RK LLAMA_BIN=$WORK/omp/bin ROUNDS=1 REPS=1 bash "$SCRIPT" "$MODEL" 2>&1); RC=$?
check "llama-bench fails everywhere: exit 1" 1 'failed' 'no results'

echo
echo "$T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ]
