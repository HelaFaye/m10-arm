#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Fetch Mario Bălănică's (@mariobalanica) "non-coherent-arm-fixes" for NVIDIA's open GPU kernel
# modules (MIT/GPLv2) at pinned commits, take only the kernel-open/ changes,
# and apply them to a user-supplied 580.95.05 aarch64 *proprietary* kernel/ tree.
#
# Nothing from that repository is redistributed here; it is downloaded at
# install time. The pinned commit IDs guarantee the exact content.
#
# *** UNTESTED WORK IN PROGRESS. ***
#
#   scripts/fetch-upstream-fixes.sh <driver>/kernel
set -eu

KDIR=${1:?usage: $0 <driver>/kernel}
REPO=https://github.com/mariobalanica/open-gpu-kernel-modules
BRANCH=non-coherent-arm-fixes
BASE=2b436058a616676ec888ef3814d1db6b2220f2eb   # NVIDIA 580.95.05
HEAD=10072734b2f88f3580cdb036778ec27d2b4f2fb9   # "Fix cached DMA allocations on non-coherent hardware"

command -v git >/dev/null || { echo "git is required"; exit 1; }
command -v patch >/dev/null || { echo "patch is required"; exit 1; }

if grep -q "nv_dev_is_dma_coherent" "$KDIR/common/inc/nv.h"; then
    echo "upstream fixes already present in $KDIR"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo ">> Fetching $REPO ($BRANCH)"
git clone -q --filter=blob:none --no-checkout "$REPO" "$TMP/ogkm"
git -C "$TMP/ogkm" fetch -q origin "$BRANCH"
git -C "$TMP/ogkm" cat-file -e "$HEAD^{commit}" || { echo "pinned commit $HEAD not found"; exit 1; }

git -C "$TMP/ogkm" diff "$BASE" "$HEAD" -- kernel-open \
    | sed 's#\([ab]\)/kernel-open/#\1/#g' > "$TMP/upstream.patch"

echo ">> Applying upstream kernel-open changes to $KDIR"
patch -d "$KDIR" -p1 --forward --no-backup-if-mismatch --quiet < "$TMP/upstream.patch"
echo ">> Upstream fixes applied"
