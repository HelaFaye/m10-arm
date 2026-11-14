#!/usr/bin/env bash
# cpu-threads-bench.sh - which CPU thread setup is fastest for llama.cpp on this board? Measured, not assumed.
#
#   ./scripts/cpu-threads-bench.sh MODEL.gguf                          # CPU only
#   ./scripts/cpu-threads-bench.sh MODEL.gguf -- -ngl 99 -ot exps=CPU  # experts on the CPU, the rest on the GPU
#   LLAMA_BIN=~/llama.cpp/build/bin ROUNDS=1 REPS=2 ./scripts/cpu-threads-bench.sh MODEL.gguf
#
# Arguments after -- go to every llama-bench run unchanged (-ngl, -ot, -p, -n, -fa, ...).
#
# On a big.LITTLE board such as RK3588 it times, for prompt processing and generation:
#   fast      the fast cores only, one thread pinned to each (what arm-cpu.sh suggests)
#   all       every core, one thread pinned to each
#   all-free  every core, threads left to the kernel's scheduler
# and each of those again with threads that wait longer before sleeping between jobs ("+spin"):
# GOMP_SPINCOUNT=3000000 for an OpenMP build (libgomp's default is 300000), --poll 100 for a build without OpenMP.
#
# Why: Llaminar's ARM work (docs/v2/projects/2026-11/arm-perf-review, ideas 05 and 13) measured on a 10+10-core
# GB10 that using every core beat the fast cores alone by 22.8%, because work handed out in small pieces keeps
# slow cores useful, and that a longer spin raised one model's decode from 13.2 to 18.7 tok/s. llama.cpp shares
# matrix work the same way but splits its smaller operations evenly between threads, the A55 is 3-4x slower than
# the A76, and the board's memory bandwidth may be the real limit, so neither result can be assumed here.
# Llaminar's method is kept: each round runs the setups in order, the next round in reverse (A B B A), and the
# rounds are averaged, so a board warming up or throttling doesn't favour whichever ran first.
#
# Threads don't change llama.cpp's arithmetic per output row, so this compares speed only.
# Testing: CHECK_ROOT=/fake/root reads /proc and /sys under that directory (tests/test-cpu-threads-bench.sh).
set -uo pipefail

MODEL=""
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,25p' "$0"; exit 0;;
    --) shift; EXTRA=("$@"); break;;
    *) if [ -n "$MODEL" ]; then echo "unexpected argument: $1 (see --help)"; exit 2; fi; MODEL=$1; shift;;
  esac
done
[ -n "$MODEL" ] || { echo "usage: $0 MODEL.gguf [-- llama-bench arguments]"; exit 2; }
[ -r "$MODEL" ] || { echo "cannot read $MODEL"; exit 2; }
ROUNDS=${ROUNDS:-2}
REPS=${REPS:-3}
SPIN=${SPIN:-3000000}

BIN=${LLAMA_BIN:-}
if [ -z "$BIN" ]; then
  for d in "$HOME/llama.cpp/build/bin" "$HOME/llama.cpp/build-cuda/bin"; do
    [ -x "$d/llama-bench" ] && { BIN=$d; break; }
  done
fi
BENCH=$BIN/llama-bench
[ -x "$BENCH" ] || { echo "no llama-bench found (set LLAMA_BIN to llama.cpp's build/bin)"; exit 2; }

# Is it an OpenMP build? (llama.cpp's default on Linux.) Without OpenMP, ggml's own thread pool uses --poll.
OPENMP=ON
CACHE=$BIN/../CMakeCache.txt
[ -r "$CACHE" ] && grep -q '^GGML_OPENMP:BOOL=OFF' "$CACHE" && OPENMP=OFF

# Cores: "<cpu> <capacity>" per line, as arm-cpu.sh reads them
R=${CHECK_ROOT:-}
CORES=$(awk '/^processor[ \t]*:/ { print $3 }' "$R/proc/cpuinfo" 2>/dev/null | while read -r c; do
  echo "$c $(cat "$R/sys/devices/system/cpu/cpu$c/cpu_capacity" 2>/dev/null || echo 1024)"; done)
[ -n "$CORES" ] || { echo "cannot read the cores from $R/proc/cpuinfo"; exit 2; }
mask() { awk '{ m += 2 ^ $1 } END { printf "0x%X", m }'; }
MAXCAP=$(echo "$CORES" | awk '{ if ($2 > m) m = $2 } END { print m }')
NALL=$(echo "$CORES" | wc -l)
NFAST=$(echo "$CORES" | awk -v m="$MAXCAP" '$2 == m' | wc -l)
ALLMASK=$(echo "$CORES" | mask)
FASTMASK=$(echo "$CORES" | awk -v m="$MAXCAP" '$2 == m' | mask)

# Setups: "name|threads|llama-bench affinity arguments"
SETUPS=()
if [ "$NFAST" -lt "$NALL" ]; then
  SETUPS+=("fast|$NFAST|-C $FASTMASK --cpu-strict 1")
fi
SETUPS+=("all|$NALL|-C $ALLMASK --cpu-strict 1" "all-free|$NALL|")
RUNS=()
for s in "${SETUPS[@]}"; do RUNS+=("$s|0" "$s|1"); done

echo "== llama-bench: $BENCH"
echo "   model: $MODEL"
[ ${#EXTRA[@]} -gt 0 ] && echo "   extra: ${EXTRA[*]}"
if [ "$OPENMP" = ON ]; then
  echo "   +spin: GOMP_SPINCOUNT=$SPIN (OpenMP build)"
else
  echo "   +spin: --poll 100 (build without OpenMP)"
fi
echo "   $NALL cores, $NFAST fast; ${#RUNS[@]} setups x $ROUNDS rounds x $REPS repetitions"

RES=$(mktemp); trap 'rm -f "$RES"' EXIT
one() {   # one <name|threads|affinity|spin>
  local name threads aff spin label
  IFS='|' read -r name threads aff spin <<<"$1"
  label=$name; [ "$spin" = 1 ] && label="$name+spin"
  local args=(-m "$MODEL" -t "$threads" -r "$REPS" -o jsonl)
  # shellcheck disable=SC2206
  [ -n "$aff" ] && args+=($aff)
  local env=()
  if [ "$spin" = 1 ]; then
    if [ "$OPENMP" = ON ]; then env=(GOMP_SPINCOUNT="$SPIN"); else args+=(--poll 100); fi
  fi
  printf '   %-14s ' "$label"
  local out
  if ! out=$(env "${env[@]}" "$BENCH" "${args[@]}" "${EXTRA[@]}" 2>/dev/null); then
    echo "failed"; return
  fi
  # jsonl: one line per test; n_prompt > 0 is prompt processing, n_gen > 0 is generation
  echo "$out" | awk -v l="$label" -v res="$RES" '
    /"avg_ts"/ {
      ng = $0; sub(/.*"n_gen": */, "", ng); sub(/[,}].*/, "", ng)
      ts = $0; sub(/.*"avg_ts": */, "", ts); sub(/[,}].*/, "", ts)
      kind = (ng + 0 > 0) ? "tg" : "pp"
      print l, kind, ts >> res; printf "%s %.2f  ", kind, ts
    }'
  echo
}

for ((round = 1; round <= ROUNDS; round++)); do
  echo
  echo "== Round $round"
  if [ $((round % 2)) -eq 1 ]; then
    for r in "${RUNS[@]}"; do one "$r"; done
  else
    for ((i = ${#RUNS[@]} - 1; i >= 0; i--)); do one "${RUNS[$i]}"; done
  fi
done

[ -s "$RES" ] || { echo; echo "no results: llama-bench failed for every setup (run one by hand to see why)"; exit 1; }

BASE=${SETUPS[0]%%|*}
echo
echo "== Average over $ROUNDS rounds (tokens/s; change against $BASE)"
awk -v base="$BASE" '
  { k = $1 SUBSEP $2; sum[k] += $3; n[k]++; if (!($1 in seen)) { seen[$1] = 1; order[++m] = $1 } }
  END {
    printf "   %-14s %16s %16s\n", "setup", "prompt (pp)", "generation (tg)"
    for (kind = 1; kind <= 2; kind++) { t = kind == 1 ? "pp" : "tg"; b[t] = n[base, t] ? sum[base, t] / n[base, t] : 0 }
    for (i = 1; i <= m; i++) {
      s = order[i]; line = sprintf("   %-14s", s)
      for (kind = 1; kind <= 2; kind++) {
        t = kind == 1 ? "pp" : "tg"
        if (!n[s, t]) { line = line sprintf(" %16s", "-"); continue }
        v = sum[s, t] / n[s, t]
        if (v > best[t]) { best[t] = v; bests[t] = s }
        line = line (b[t] > 0 && s != base ? sprintf(" %8.2f %+6.1f%%", v, 100 * (v / b[t] - 1)) : sprintf(" %8.2f        ", v))
      }
      print line
    }
    print ""
    for (kind = 1; kind <= 2; kind++) { t = kind == 1 ? "pp" : "tg"
      if (bests[t] != "") printf "   fastest %s: %s\n", (t == "pp" ? "prompt processing" : "generation"), bests[t] }
  }' "$RES"
echo
echo "   A difference within a few percent is noise; run more rounds (ROUNDS=4) before changing your setup."
echo "   The winning setup's flags: fast = -t $NFAST -C $FASTMASK --cpu-strict 1; all = -t $NALL -C $ALLMASK"
echo "   --cpu-strict 1; all-free = -t $NALL. +spin: GOMP_SPINCOUNT=$SPIN in the environment (or --poll 100)."
