#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Automatic test of the whole stack on real hardware: Tesla M10 on the
# Orange Pi 5 Plus with the patched driver. Runs every check in order, keeps
# going after failures, and writes a report to attach to an issue.
#
# *** UNTESTED WORK IN PROGRESS - can hang or crash the board. ***
#
#   sudo scripts/hw-test.sh [options]
#
#   --quick            short run (default)
#   --full             more sizes and rounds, every ggml op, module reload test
#   --soak MINUTES     afterwards, repeat the CUDA tests for MINUTES
#   --model FILE.gguf  also compare the model's perplexity on GPU and CPU
#   --llama DIR        llama.cpp tree from build-llama.sh (default ./llama.cpp)
#   --venv DIR         PyTorch venv from build-torch.sh (default ./torch-venv)
#   --out DIR          where results go (default ./m10-test-results)
#
# Environment: EXPECT_GPUS (4), TEMP_LIMIT in C (85), PPL_TOL in % (2),
# CUDA_HOME (/usr/local/cuda-12.9), M10_SELFTEST (prebuilt self-test binary).
#
# Every stage passes, fails or is skipped (when its prerequisite isn't
# installed). A stage also fails if the kernel logs an Xid, oops, SError or
# similar while it runs. The current stage is saved to disk before it starts,
# so if the board hangs or reboots, the next run says where it stopped.
# Exit status: 0 if nothing failed, 1 otherwise.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
EXPECT_GPUS=${EXPECT_GPUS:-4}
TEMP_LIMIT=${TEMP_LIMIT:-85}
PPL_TOL=${PPL_TOL:-2}
CUDA_HOME=${CUDA_HOME:-/usr/local/cuda-12.9}
R=${M10_TEST_ROOT:-}   # test hook: prefix for /proc and /sys reads (empty on the board)
MODE=quick SOAK=0 MODEL="" LLAMA=$PWD/llama.cpp VENV=$PWD/torch-venv OUT=$PWD/m10-test-results

usage() { sed -n '/^#   sudo/,/^#   --out/s/^# \{0,1\}//p' "$0"; }
while [ $# -gt 0 ]; do
    case $1 in
        --quick) MODE=quick ;;
        --full) MODE=full ;;
        --soak) SOAK=${2:?--soak needs MINUTES}; shift ;;
        --model) MODEL=${2:?--model needs a file}; shift ;;
        --llama) LLAMA=${2:?}; shift ;;
        --venv) VENV=${2:?}; shift ;;
        --out) OUT=${2:?}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
    shift
done
case $SOAK in *[!0-9]*) echo "--soak takes whole minutes"; exit 2 ;; esac
[ -z "$MODEL" ] || [ -f "$MODEL" ] || { echo "No such model: $MODEL"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "Run with sudo: loading modules and reading the kernel log need root."; exit 1; }

if [ "$MODE" = full ]; then ROUNDS=16 SIZES="1 64 256" OPS=all
else                         ROUNDS=4  SIZES="1 64"     OPS=quick; fi
QUICK_OPS=MUL_MAT,MUL_MAT_ID,GET_ROWS,CPY,ADD,MUL,RMS_NORM,ROPE,SOFT_MAX,FLASH_ATTN_EXT
KERR='NVRM: Xid|Oops|BUG:|Call trace|Unable to handle|SError|Internal error|fallen off the bus|RmInitAdapter failed|soft lockup|hung_task|rcu.*stall|Kernel panic'

# --- A run that never finished means the board hung or crashed
mkdir -p "$OUT"
for r in "$OUT"/*/RUNNING; do
    [ -e "$r" ] || continue
    echo "!! Previous run $(dirname "$r") stopped during stage: $(cat "$r")"
    echo "   (hang, crash or reboot?) Its logs are still there; please include them."
    mv "$r" "$(dirname "$r")/UNFINISHED"
done

RUNID=$(date +%Y%m%d-%H%M%S)
RUN=$OUT/$RUNID
mkdir -p "$RUN/bin"
exec 3>&1                               # the console, for note()
echo "M10 hardware test $RUNID ($MODE) -> $RUN"
echo "start $(date)" > "$RUN/RUNNING"

note() { echo "   $*" >&3; echo "$*"; }
kmark() { echo "m10-hw-test[$RUNID]: $*" > /dev/kmsg 2>/dev/null; }
kmsg_since() {   # kernel log since a marker, or since a line count if marking failed
    if dmesg | grep -qF "m10-hw-test[$RUNID]: $1"; then
        dmesg | awk -v m="m10-hw-test[$RUNID]: $1" 'on; index($0, m) { on = 1 }'
    else
        dmesg | tail -n +"$(($2 + 1))"
    fi
}

# --- Thermal watchdog: logs temperatures; on overheating it stops the heavy
# stage that is running (only the processes that stage started) and the rest
# of the heavy stages are skipped. The M10 has no fan of its own.
kill_tree() {
    for c in $(pgrep -P "$1"); do kill_tree "$c"; done
    kill -TERM "$1" 2>/dev/null
}
watchdog() {
    while [ -e "$RUN/RUNNING" ]; do
        q=$(timeout 20 nvidia-smi --query-gpu=index,temperature.gpu,power.draw,utilization.gpu,clocks.sm \
            --format=csv,noheader,nounits 2>/dev/null) && {
            echo "$q" | sed "s/^/$(date +%s), /" >> "$RUN/thermal.csv"
            hot=$(echo "$q" | awk -F', *' -v lim="$TEMP_LIMIT" '$2 + 0 >= lim { printf "%sGPU%s %sC", (n++ ? " " : ""), $1, $2 }')
            if [ -n "$hot" ]; then
                [ -e "$RUN/OVERHEAT" ] || echo "$hot" > "$RUN/OVERHEAT"
                [ -s "$RUN/heavy.pid" ] && kill_tree "$(cat "$RUN/heavy.pid")"
            fi
        }
        sleep 10
    done
}
watchdog &

FAILS=0
# stage <id> <title> <function> <heavy:0|1>
stage() {
    printf '%s %s (started %s)\n' "$1" "$2" "$(date +%T)" > "$RUN/RUNNING"
    sync
    printf '\n== %s %s\n' "$1" "$2"
    if [ "$4" = 1 ] && [ -e "$RUN/OVERHEAT" ]; then
        result SKIP "$1" "$2" 0 "GPUs overheated earlier ($(cat "$RUN/OVERHEAT"))"
        return
    fi
    base=$(dmesg 2>/dev/null | wc -l)
    kmark "stage $1 begin"
    t0=$(date +%s)
    # A heavy stage records its subshell's PID for the watchdog
    ( [ "$4" = 1 ] && sh -c 'echo $PPID' > "$RUN/heavy.pid"; "$3" ) > "$RUN/$1.log" 2>&1
    rc=$?
    rm -f "$RUN/heavy.pid"
    t=$(($(date +%s) - t0))
    kmsg_since "stage $1 begin" "$base" > "$RUN/$1.dmesg" 2>/dev/null
    kerr=$(grep -E "$KERR" "$RUN/$1.dmesg" | grep -v m10-hw-test)
    if [ -n "$kerr" ]; then
        echo "$kerr" | head -5 | sed 's/^/   kernel: /'
        result FAIL "$1" "$2" "$t" "kernel errors (see $1.dmesg)"
    elif [ "$4" = 1 ] && [ -e "$RUN/OVERHEAT" ]; then
        result FAIL "$1" "$2" "$t" "stopped: GPUs overheated ($(cat "$RUN/OVERHEAT")); improve airflow"
    elif [ $rc = 0 ]; then
        result PASS "$1" "$2" "$t" ""
    elif [ $rc = 77 ]; then
        result SKIP "$1" "$2" "$t" "$(tail -n 1 "$RUN/$1.log")"
    else
        tail -n 12 "$RUN/$1.log" | sed 's/^/   | /'
        result FAIL "$1" "$2" "$t" "exit $rc (see $1.log)"
    fi
}
result() {   # result <PASS|FAIL|SKIP> <id> <title> <seconds> <note>
    [ "$1" = FAIL ] && FAILS=$((FAILS + 1))
    printf '%-4s %-3s %-34s %5ss  %s\n' "$1" "$2" "$3" "$4" "$5" | tee -a "$RUN/summary.txt"
}
skip() { echo "$*"; exit 77; }

# Count lines in "$2" matching "$1" (grep -c prints 0 but exits 1 on none)
count() { grep -cE "$1" "$2" || true; }

# --- Stages ------------------------------------------------------------------

st_sysinfo() {
    uname -a; cat /etc/os-release /etc/armbian-release 2>/dev/null
    grep -E "^(model name|CPU part)" /proc/cpuinfo | sort | uniq -c
    free -h; cat /proc/cmdline; df -h "$OUT"
    modinfo -F version nvidia 2>/dev/null | sed 's/^/nvidia module /'
    git -C "$HERE" rev-parse HEAD 2>/dev/null | sed 's/^/m10-arm commit /'
    note "kernel $(uname -r), $(nproc) CPUs, $(free -g | awk '/^Mem:/ { print $2 }') GB RAM"
}

st_pcie() {
    lspci -tv; lspci -nn | grep -iE "nvidia|10de|10b5|plx"
    lspci -vvv -d 10de:13bd > "$RUN/lspci-m10.txt" 2>&1
    n=$(lspci -n -d 10de:13bd | wc -l)
    note "M10 GPUs on PCIe: $n (expected $EXPECT_GPUS)"
    for d in $(lspci -n -d 10de:13bd | cut -d' ' -f1); do
        note "$d $(lspci -vv -s "$d" | grep -oE 'LnkSta:[^,]*, Width x[0-9]+' | head -1)"
    done
    ok=1
    if grep -q unassigned "$RUN/lspci-m10.txt"; then
        note "!! some BARs are unassigned: the PCIe address window is too small"
        ok=0
    fi
    [ "$n" -ge "$EXPECT_GPUS" ] && [ $ok = 1 ]
}

st_driver() {
    grep -q '^nvidia ' "$R"/proc/modules || modprobe nvidia || { note "modprobe nvidia failed"; return 1; }
    grep -q '^nvidia_uvm ' "$R"/proc/modules || modprobe nvidia-uvm || { note "modprobe nvidia-uvm failed"; return 1; }
    [ -e "$R/sys/module/nvidia/parameters/arm_force_uncached" ] ||
        { note "!! nvidia has no arm_* parameters: this is not the patched driver"; return 1; }
    for p in arm_force_uncached arm_disable_iomap_wc arm_assume_noncoherent arm_allow_host_register; do
        note "nvidia.$p = $(cat "$R/sys/module/nvidia/parameters/$p")"
    done
    note "nvidia_uvm.uvm_arm_uncached_sysmem = $(cat "$R/sys/module/nvidia_uvm/parameters/uvm_arm_uncached_sysmem" 2>/dev/null)"
    dmesg | grep -E "NVRM: arm64|nvidia-uvm: arm64|NVRM: loading" > "$RUN/driver-lines.txt"
    cat "$RUN/driver-lines.txt"
    # One line per GPU from nvidia.ko (nvidia-uvm prints its own, not counted)
    nc=$(count "NVRM: arm64: .*DMA NON-coherent" "$RUN/driver-lines.txt")
    co=$(count "NVRM: arm64: .*DMA coherent" "$RUN/driver-lines.txt")
    note "GPUs reported non-coherent: $nc, coherent: $co"
    if [ "$co" -gt 0 ]; then
        if [ "$(cat "$R/sys/module/nvidia/parameters/arm_assume_noncoherent")" = 0 ]; then
            note "(coherent because arm_assume_noncoherent=0 was set)"
        else
            note "!! the kernel reports coherent DMA, so the RK3588 fixes are off for those GPUs."
            note "   Try: options nvidia arm_assume_noncoherent=1 in /etc/modprobe.d/"
            return 1
        fi
    fi
    [ "$nc" -ge "$EXPECT_GPUS" ] || note "(fewer lines than GPUs: the boot log may have rotated)"
}

st_smi() {
    command -v nvidia-smi >/dev/null || { note "nvidia-smi missing"; return 1; }
    timeout 120 nvidia-smi -L | tee "$RUN/smi-L.txt" || return 1
    n=$(count "Tesla M10" "$RUN/smi-L.txt")
    note "nvidia-smi sees $n Tesla M10 GPUs (expected $EXPECT_GPUS)"
    timeout 120 nvidia-smi --query-gpu=index,pci.bus_id,vbios_version,temperature.gpu,power.draw,pcie.link.gen.current,pcie.link.width.current,memory.total \
        --format=csv | tee "$RUN/smi-query.csv" | sed 's/^/   /' >&3
    timeout 300 nvidia-smi -q > "$RUN/nvidia-smi-q.txt" 2>&1
    [ "$n" -ge "$EXPECT_GPUS" ]
}

selftest_bin() {   # prints the self-test binary, building it on first use
    if [ -n "${M10_SELFTEST:-}" ]; then echo "$M10_SELFTEST"; return; fi
    b=$RUN/bin/m10_cuda_selftest
    if [ ! -x "$b" ]; then
        [ -x "$CUDA_HOME/bin/nvcc" ] || return 1
        "$CUDA_HOME/bin/nvcc" -O2 -arch=sm_50 -Wno-deprecated-gpu-targets \
            -o "$b" "$HERE/tests/m10_cuda_selftest.cu" >&2 || return 1
    fi
    echo "$b"
}

st_cuda() {
    b=$(selftest_bin) || skip "CUDA toolkit not found in $CUDA_HOME (run scripts/setup-cuda.sh)"
    timeout 3600 "$b" "$ROUNDS" 64 > "$RUN/05-selftest.log" 2>&1
    rc=$?
    cat "$RUN/05-selftest.log"
    note "$(count ' ok( |$)' "$RUN/05-selftest.log") checks ok, $(count ' FAIL( |$)' "$RUN/05-selftest.log") failed"
    return $rc
}

st_cuda_concurrent() {   # all GPUs at once, one process each
    b=$(selftest_bin) || skip "CUDA toolkit not found"
    pids=""
    i=0
    while [ $i -lt "$EXPECT_GPUS" ]; do
        CUDA_VISIBLE_DEVICES=$i timeout 3600 "$b" "$ROUNDS" 64 > "$RUN/06-gpu$i.log" 2>&1 &
        pids="$pids $!"
        i=$((i + 1))
    done
    ok=1
    i=0
    for p in $pids; do
        if wait "$p"; then note "GPU$i: PASS"; else note "GPU$i: FAIL (06-gpu$i.log)"; ok=0; fi
        i=$((i + 1))
    done
    [ $ok = 1 ]
}

st_cuda_sizes() {
    b=$(selftest_bin) || skip "CUDA toolkit not found"
    ok=1
    for mib in $SIZES; do
        if timeout 3600 "$b" 2 "$mib" > "$RUN/07-${mib}MiB.log" 2>&1; then
            note "$mib MiB buffers: PASS"
        else
            note "$mib MiB buffers: FAIL (07-${mib}MiB.log)"; ok=0
        fi
    done
    [ $ok = 1 ]
}

st_vulkan() {
    [ -e /usr/share/vulkan/icd.d/nvidia_icd.json ] || [ -e /etc/vulkan/icd.d/nvidia_icd.json ] ||
        skip "NVIDIA Vulkan driver not installed (install.sh --with-vulkan)"
    sh "$HERE/scripts/check-vulkan.sh"
}

st_llama_ops() {
    any=0 ok=1
    for be in cuda vulkan; do
        t=$LLAMA/build-$be/bin/test-backend-ops
        [ -x "$t" ] || continue
        any=1
        log=$RUN/09-$be.log
        if [ "$OPS" = quick ]; then
            LD_LIBRARY_PATH=$CUDA_HOME/lib64 timeout 7200 "$t" test -o "$QUICK_OPS" > "$log" 2>&1
        else
            LD_LIBRARY_PATH=$CUDA_HOME/lib64 timeout 14400 "$t" test > "$log" 2>&1
        fi
        rc=$?
        n=$(count '^Backend [0-9]+/[0-9]+: (CUDA|Vulkan)[0-9]' "$log")
        f=$(count 'FAIL' "$log")
        note "$be: $n GPUs tested, $f failures, exit $rc"
        [ $rc = 0 ] && [ "$n" -ge "$EXPECT_GPUS" ] || ok=0
    done
    [ $any = 1 ] || skip "no llama.cpp build in $LLAMA (scripts/build-llama.sh)"
    [ $ok = 1 ]
}

ppl() {   # ppl <label> <llama-perplexity args...>: prints the PPL value
    label=$1; shift
    LD_LIBRARY_PATH=$CUDA_HOME/lib64 timeout 3600 "$LLAMA/build-cuda/bin/llama-perplexity" \
        -m "$MODEL" -f "$HERE/README.md" -c 128 --chunks 8 "$@" > "$RUN/10-$label.log" 2>&1
    sed -n 's/.*Final estimate: PPL = \([0-9.]*\).*/\1/p' "$RUN/10-$label.log"
}

st_llama_model() {
    [ -n "$MODEL" ] || skip "no --model given"
    [ -x "$LLAMA/build-cuda/bin/llama-perplexity" ] || skip "no CUDA llama.cpp build in $LLAMA"
    # Perplexity over a fixed text must match between CPU and GPU (within
    # numerical noise); stale data from a coherency bug makes it diverge.
    cpu=$(ppl cpu -dev none -ngl 0)
    all=$(ppl gpu-all -ngl 99 -sm layer)
    one=$(ppl gpu-one -ngl 99 -sm none -mg 0)
    note "perplexity: CPU ${cpu:-?}, all GPUs ${all:-?}, GPU0 only ${one:-?} (tolerance ${PPL_TOL}%)"
    [ -n "$cpu" ] || { note "CPU reference failed (10-cpu.log)"; return 1; }
    ok=1
    for v in "all:$all" "one:$one"; do
        x=${v#*:}
        [ -n "$x" ] || { note "${v%%:*}: no result"; ok=0; continue; }
        awk -v a="$x" -v b="$cpu" -v t="$PPL_TOL" 'BEGIN { d = (a - b) / b * 100; if (d < 0) d = -d; exit !(d <= t) }' ||
            { note "${v%%:*}: differs from CPU by more than ${PPL_TOL}%"; ok=0; }
    done
    LD_LIBRARY_PATH=$CUDA_HOME/lib64 timeout 1800 "$LLAMA/build-cuda/bin/llama-bench" \
        -m "$MODEL" -ngl 99 -sm layer -p 128 -n 32 -r 2 > "$RUN/10-bench.log" 2>&1 &&
        grep -E '^\|' "$RUN/10-bench.log" | sed 's/^/   /' >&3
    [ $ok = 1 ]
}

st_torch() {
    [ -x "$VENV/bin/python" ] || skip "no PyTorch venv in $VENV (scripts/build-torch.sh)"
    "$VENV/bin/python" -c 'import torch' || { note "torch doesn't import"; return 1; }
    timeout 3600 "$VENV/bin/python" "$HERE/tests/torch_selftest.py" --expect-gpus "$EXPECT_GPUS" \
        --rounds "$ROUNDS"
}

st_reload() {   # unload and reload the modules; runs in --full only
    [ "$MODE" = full ] || skip "only with --full"
    b=$(selftest_bin) || skip "CUDA toolkit not found"
    i=1
    while [ $i -le 3 ]; do
        users=$(awk '$1 == "nvidia" { print $3 }' "$R"/proc/modules)
        for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
            grep -q "^$m " "$R"/proc/modules || continue
            rmmod "$m" 2>&1 ||
                skip "can't unload $m ($users users of nvidia; stop nvidia-persistenced and GPU apps first)"
        done
        modprobe -a nvidia nvidia-uvm || { note "reload $i: modprobe failed"; return 1; }
        timeout 1800 "$b" 1 16 > "$RUN/12-reload$i.log" 2>&1 || { note "reload $i: self-test FAIL"; return 1; }
        note "reload $i: PASS"
        i=$((i + 1))
    done
}

st_soak() {
    [ "$SOAK" -gt 0 ] || skip "no --soak given"
    b=$(selftest_bin) || skip "CUDA toolkit not found"
    end=$(($(date +%s) + SOAK * 60))
    it=0 sizes="1 16 64 128"
    while [ "$(date +%s)" -lt "$end" ] && [ ! -e "$RUN/OVERHEAT" ]; do
        it=$((it + 1))
        mib=$(echo "$sizes" | cut -d' ' -f$(( (it % 4) + 1 )))
        timeout 3600 "$b" 2 "$mib" > "$RUN/13-iter.log" 2>&1 ||
            { cp "$RUN/13-iter.log" "$RUN/13-fail-iter$it.log"; note "iteration $it ($mib MiB): FAIL"; return 1; }
    done
    note "$it iterations in $SOAK minutes, all passed"
}

# --- Run ---------------------------------------------------------------------
kmark "run start ($MODE)"
stage 01 "System information"          st_sysinfo 0
stage 02 "PCIe: 4 GPUs, BARs assigned"  st_pcie 0
stage 03 "Patched driver loaded"        st_driver 0
stage 04 "nvidia-smi"                   st_smi 0
stage 05 "CUDA self-test, all GPUs"     st_cuda 1
stage 06 "CUDA self-test, concurrent"   st_cuda_concurrent 1
stage 07 "CUDA self-test, buffer sizes" st_cuda_sizes 1
stage 08 "Vulkan"                       st_vulkan 0
stage 09 "llama.cpp ops vs CPU"         st_llama_ops 1
stage 10 "Model perplexity GPU vs CPU"  st_llama_model 1
stage 11 "PyTorch self-test"            st_torch 1
stage 12 "Module unload/reload"         st_reload 1
stage 13 "Soak"                         st_soak 1
kmark "run end"

# --- Report ------------------------------------------------------------------
rm -f "$RUN/RUNNING"           # also stops the watchdog
wait 2>/dev/null
dmesg > "$RUN/dmesg-full.txt" 2>/dev/null
if [ -s "$RUN/thermal.csv" ]; then
    printf '\nHighest temperatures: '
    awk -F', *' '{ if ($3 + 0 > m[$2]) m[$2] = $3 + 0 } END { for (g in m) printf "GPU%s %sC  ", g, m[g]; print "" }' \
        "$RUN/thermal.csv" | tee -a "$RUN/summary.txt"
fi
tar -czf "$RUN.tar.gz" -C "$OUT" "$RUNID" 2>/dev/null
echo
echo "== Summary ($FAILS failed)"
cat "$RUN/summary.txt"
echo
echo "Report: $RUN.tar.gz  (attach it to an issue)"
[ "$FAILS" = 0 ]
