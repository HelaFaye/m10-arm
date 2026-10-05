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
#   sudo scripts/install.sh [--patch-only] [--with-vulkan] /path/to/NVIDIA-Linux-aarch64-580.95.05.run
#
# --with-vulkan also installs NVIDIA's GL/Vulkan user-space libraries, which
# its Vulkan driver lives in. Ubuntu's libglvnd is kept, and NVIDIA's EGL
# vendor file is disabled so the desktop keeps using Mesa (Mali) for EGL.
set -eu

USAGE="usage: sudo $0 [--patch-only] [--with-vulkan] /path/to/NVIDIA-Linux-aarch64-580.95.05.run"
PATCH_ONLY=0
VULKAN=0
while [ $# -gt 0 ]; do
    case $1 in
        --patch-only) PATCH_ONLY=1 ;;
        --with-vulkan) VULKAN=1 ;;
        -*) echo "$USAGE"; exit 2 ;;
        *) break ;;
    esac
    shift
done
RUN=${1:?$USAGE}

HERE=$(cd "$(dirname "$0")/.." && pwd)
KVER=$(uname -r)
WORK=${WORK:-$PWD/NVIDIA-Linux-aarch64-580.95.05-m10}

[ -f "$RUN" ] || { echo "No such file: $RUN"; exit 1; }
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

# Patching works anywhere; installing only on the board itself.
[ "$(uname -m)" = aarch64 ] || { echo "Run this on the Arm board (aarch64)."; exit 1; }
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

# --no-opengl-files     : keep Mesa (Mali/panthor) GL/EGL for the desktop. This
#                         also leaves out NVIDIA's Vulkan driver, which ships
#                         in the same libraries.
# --no-install-libglvnd : with --with-vulkan, keep Ubuntu's libglvnd dispatch
#                         libraries rather than replacing them.
# --no-drm              : the M10 has no display outputs; skip nvidia-drm
# libcuda, nvidia-smi and the nvidia-uvm module (needed by CUDA) are installed.
if [ "$VULKAN" = 1 ]; then
    [ -e /usr/lib/aarch64-linux-gnu/libGLdispatch.so.0 ] || {
        echo "--with-vulkan needs Ubuntu's libglvnd: sudo apt install libglvnd0"
        exit 1; }
    GL_OPT=--no-install-libglvnd
else
    GL_OPT=--no-opengl-files
fi

echo ">> Running nvidia-installer"
cd "$WORK"
./nvidia-installer \
    --kernel-module-type=proprietary \
    "$GL_OPT" \
    --no-drm \
    --no-x-check \
    --no-nouveau-check \
    --skip-module-load \
    --ui=none --no-questions --accept-license

if [ "$VULKAN" = 1 ]; then
    # glvnd tries EGL vendors in file-name order, so NVIDIA's 10_nvidia.json
    # would come before Mesa's 50_mesa.json for every desktop EGL app. The M10
    # drives no display, so turn it off. Vulkan doesn't use EGL.
    for f in /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
             /etc/glvnd/egl_vendor.d/10_nvidia.json; do
        if [ -e "$f" ]; then
            mv "$f" "$f.disabled-by-m10-arm"
            echo ">> Disabled NVIDIA EGL vendor: $f"
        fi
    done
    echo ">> Vulkan installed. After reboot: scripts/check-vulkan.sh"
fi

echo ">> Done. Then:"
echo "     sudo update-initramfs -u && sudo reboot"
echo "     sudo modprobe -a nvidia nvidia-uvm && sudo dmesg | grep -E 'NVRM|nvidia' && nvidia-smi"
