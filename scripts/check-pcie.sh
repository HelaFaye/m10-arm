#!/bin/sh
# SPDX-License-Identifier: MIT
# Pre-install check: are the M10's four GPUs and PCIe switch visible, with BARs assigned?
# Run with sudo. Paste the output into an issue if anything looks wrong.

[ "$(id -u)" = 0 ] || echo "!! Not root: lspci hides link status (LnkSta) and dmesg may be unreadable. Use sudo."

echo "== PCIe tree"; lspci -tv
echo; echo "== NVIDIA devices"
lspci -nn -d 10de: || true
echo; echo "== BARs / link"
lspci -vvv -d 10de: 2>/dev/null | grep -E "^[0-9a-f]|Region|LnkSta:|Kernel (driver|modules)"
echo; echo "== Problems"
if lspci -vvv -d 10de: 2>/dev/null | grep -q "unassigned"; then
    echo "!! Some BARs are unassigned: the PCIe address window is too small (device tree fix needed)."
fi
if ! dmesg >/dev/null 2>&1; then
    echo "!! Can't read dmesg (run with sudo); BAR assignment errors not checked."
else
    dmesg | grep -iE "BAR .*(no space|failed)|can't assign" || echo "no BAR assignment errors in dmesg"
fi
n=$(lspci -n -d 10de:13bd | wc -l)
echo "M10 GPUs found: $n (expected 4)"
