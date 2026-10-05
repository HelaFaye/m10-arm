#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Check that NVIDIA's Vulkan driver sees the M10's four GPUs. Needs the driver
# installed with scripts/install.sh --with-vulkan, and `sudo apt install
# vulkan-tools` for vulkaninfo. For a compute correctness check, run
# scripts/build-llama.sh --vulkan afterwards.
#
# *** UNTESTED WORK IN PROGRESS. ***

command -v vulkaninfo >/dev/null || { echo "vulkaninfo missing: sudo apt install vulkan-tools"; exit 1; }

echo "== NVIDIA Vulkan driver manifest"
icd=""
for f in /usr/share/vulkan/icd.d/nvidia_icd.json /etc/vulkan/icd.d/nvidia_icd.json; do
    [ -e "$f" ] && { icd=$f; echo "$f"; }
done
if [ -z "$icd" ]; then
    echo "!! Not found. Reinstall with: sudo scripts/install.sh --with-vulkan <file.run>"
    exit 1
fi

echo; echo "== Devices"
summary=$(vulkaninfo --summary 2>&1)
echo "$summary" | grep -E "deviceName|driverName|apiVersion|driverVersion"
n=$(echo "$summary" | grep -c "deviceName.*Tesla M10" || true)
echo; echo "Tesla M10 Vulkan devices: $n (expected 4)"

if [ "$n" -eq 0 ]; then
    echo "!! NVIDIA's driver didn't enumerate any GPU. Check:"
    echo "   VK_LOADER_DEBUG=driver vulkaninfo --summary 2>&1 | grep -i nvidia"
    echo "   ls -l /dev/nvidia*   (nvidia and nvidia-uvm must be loaded)"
    exit 1
fi
[ "$n" -eq 4 ] || exit 1
echo ">> OK. Next: scripts/build-llama.sh --vulkan"
