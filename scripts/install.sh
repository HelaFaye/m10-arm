#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Patch and install NVIDIA 580.95.05 (aarch64, proprietary kernel module) for a
# Tesla M10 on a non-cache-coherent Arm host (Orange Pi 5 Plus / RK3588).
#
# *** UNTESTED WORK IN PROGRESS - may hang or crash your system. ***
#
# You must supply NVIDIA's installer yourself:
#   NVIDIA-Linux-aarch64-580.95.05.run
#
#   sudo scripts/install.sh [--patch-only] /path/to/NVIDIA-Linux-aarch64-580.95.05.run
set -eu

PATCH_ONLY=0
if [ "${1:-}" = "--patch-only" ]; then PATCH_ONLY=1; shift; fi
RUN=${1:?usage: sudo $0 [--patch-only] /path/to/NVIDIA-Linux-aarch64-580.95.05.run}

HERE=$(cd "$(dirname "$0")/.." && pwd)
KVER=$(uname -r)
WORK=${WORK:-$PWD/NVIDIA-Linux-aarch64-580.95.05-m10}

[ -f "$RUN" ] || { echo "No such file: $RUN"; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "Run this on the Arm board (aarch64)."; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }

echo "!! This is untested work-in-progress code. Continue? [y/N]"
read -r ans; [ "$ans" = y ] || [ "$ans" = Y ] || exit 1

echo ">> Extracting $RUN -> $WORK"
rm -rf "$WORK"
sh "$RUN" -x --target "$WORK" >/dev/null

python3 "$HERE/patcher/m10_arm_patcher.py" verify-stock "$WORK/kernel"
sh "$HERE/scripts/fetch-upstream-fixes.sh" "$WORK/kernel"
python3 "$HERE/patcher/m10_arm_patcher.py" apply "$WORK/kernel"

if [ "$PATCH_ONLY" = 1 ]; then
    echo ">> Patched driver tree ready at $WORK (not installed)"
    exit 0
fi

[ "$(id -u)" = 0 ] || { echo "Installing needs root (sudo)."; exit 1; }
[ -e "/lib/modules/$KVER/build/Makefile" ] || {
    echo "Kernel headers for $KVER missing. On Armbian install the linux-headers"
    echo "package matching your linux-image package (or use armbian-config)."
    exit 1; }

echo ">> Blacklisting nouveau"
cat > /etc/modprobe.d/blacklist-nouveau-m10.conf <<'B'
blacklist nouveau
options nouveau modeset=0
B

# --no-opengl-files : keep Mesa (Mali/panthor) GL/EGL for the desktop
# --no-drm          : the M10 has no display outputs; skip nvidia-drm
# libcuda, nvidia-smi and the nvidia-uvm module (needed by CUDA) are installed.
echo ">> Running nvidia-installer"
cd "$WORK"
./nvidia-installer \
    --kernel-module-type=proprietary \
    --no-opengl-files \
    --no-drm \
    --no-x-check \
    --no-nouveau-check \
    --skip-module-load \
    --ui=none --no-questions --accept-license

echo ">> Done. Then:"
echo "     sudo update-initramfs -u && sudo reboot"
echo "     sudo modprobe nvidia nvidia-uvm && sudo dmesg | grep -E 'NVRM|nvidia' && nvidia-smi"
