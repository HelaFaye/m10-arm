#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# m10_arm_patcher.py - patches the kernel-interface sources of a user-supplied
# NVIDIA 580.95.05 aarch64 driver so the proprietary kernel module can drive a
# Tesla M10 (Maxwell) on a non-cache-coherent Arm PCIe host (RK3588).
#
# *** UNTESTED WORK IN PROGRESS. ***
#
# Copyright (c) 2026 HelaFaye. Approach based on Mario Bălănică's
# non-coherent-arm-fixes for open-gpu-kernel-modules (see CREDITS.md).
#
# This file contains no NVIDIA code. It edits files in a driver tree that you
# extracted yourself from NVIDIA's .run installer, locating edit points by short
# one-line anchors.
#
# Usage:
#   m10_arm_patcher.py verify-stock <driver>/kernel   # before any patching
#   m10_arm_patcher.py apply        <driver>/kernel   # after upstream fixes
#   m10_arm_patcher.py check        <driver>/kernel   # is it already applied?

import hashlib
import os
import sys

MARKER = "M10/RK3588 port"

# sha256 of the stock 580.95.05 aarch64 files this project touches (directly or
# via the upstream non-coherent-arm-fixes diff). Used only to refuse to patch
# a different driver version.
STOCK_SHA256 = {
    "common/inc/nv.h":           "8b3c5b3c3c295f7dbfa79045ace39142a307db600ababb42d90562b428c5e7b4",
    "common/inc/os-interface.h": "4849df93877a2a7dd020204be28237802646de7f419920f482adb9735a14484b",
    "nvidia/os-interface.c":     "b1adceee686839ce6cc0b91a6f96081bbe0b45132a49b69571723045bee6081e",
    "nvidia/nv-mmap.c":          "648e2aa8cb3f6a279a6b7c9205c98402a10d7532821a7e2cb06d19b8be5e30b9",
    "nvidia/nv-dma.c":           "bde346614f62a08f49888d9078b551f99027e459e8e34821ca4a275b5b3f5ec7",
    "nvidia/nv-pci.c":           "2d7b78ef2d5356adff1138157e34c67a317bec029d81337504e27dd702740a24",
    "nvidia/nv.c":               "0648b6916ef56e7aed794c3182c0edf8e2202a29f373e3ed92f35a9b6f4f64c0",
    "conftest.sh":               "c71cc38b324c1be430d05177b60e11957db6fc472806d025c2483ffbf79fa3d4",
    "nvidia/nvidia.Kbuild":      "b506769bef3e343ac0c7a4750e1ab30bdc8963a3b5c1d450ab10041169c9f4ed",
}

# ---------------------------------------------------------------------------
# Code inserted by this project (original work)
# ---------------------------------------------------------------------------

NV_H_DECLS = """
/*
 * M10/RK3588 port: the proprietary RM (nv-kernel.o_binary) still imports the
 * pre-"non-coherent-arm-fixes" interface, so keep these entry points alive.
 */
void       NV_API_CALL  nv_dma_cache_invalidate  (nv_dma_device_t *, void *);

/* M10/RK3588 port: non-coherent Arm policy helpers (nv.c) */
NvBool                  nv_arm_is_noncoherent    (nv_state_t *);
void                    nv_arm_note_device       (nv_state_t *);
NvBool                  nv_arm_disable_iomap_wc  (void);
"""

OS_INTERFACE_H_DECLS = """\
/* M10/RK3588 port: still imported by the proprietary RM blob */
NV_STATUS   NV_API_CALL  os_flush_cpu_cache_all           (void);
NV_STATUS   NV_API_CALL  os_flush_user_cache              (void);
"""

OS_INTERFACE_C_SHIMS = r"""/*
 * M10/RK3588 port: compatibility shims for the proprietary RM.
 *
 * The RM calls these with no address range. arm64 has no reliable way to
 * clean/invalidate the entire cache hierarchy (flush_cache_all() was removed
 * in 4.2), and the stock implementation silently did nothing. On non-coherent
 * platforms this port instead forces RM system memory to uncached (Normal-NC)
 * mappings in nv_alloc_pages(), which makes a whole-cache flush unnecessary
 * for those allocations. We log once so it's visible if the RM relies on it.
 */
NV_STATUS NV_API_CALL os_flush_cpu_cache_all(void)
{
#if defined(NVCPU_AARCH64)
    if (nv_arm_is_noncoherent(NULL))
    {
        printk_once(KERN_INFO "NVRM: arm64: RM requested a full CPU cache flush "
                    "(not possible on arm64); relying on uncached sysmem.\n");
    }
    mb();
    return NV_OK;
#else
    return NV_ERR_NOT_SUPPORTED;
#endif
}

NV_STATUS NV_API_CALL os_flush_user_cache(void)
{
#if defined(NVCPU_AARCH64)
    if (!NV_MAY_SLEEP())
        return NV_ERR_NOT_SUPPORTED;

    if (nv_arm_is_noncoherent(NULL))
    {
        printk_once(KERN_INFO "NVRM: arm64: user cache flush requested; "
                    "cached user mappings are not maintained on this platform.\n");
    }
    mb();
    return NV_OK;
#else
    return NV_ERR_NOT_SUPPORTED;
#endif
}

"""

NV_DMA_C_SHIM = """/*
 * M10/RK3588 port: blob ABI compat. The stock implementation used
 * dma_sync_*_for_device(), which cleans rather than invalidates on arm64.
 */
void NV_API_CALL nv_dma_cache_invalidate
(
    nv_dma_device_t *dma_dev,
    void *priv
)
{
    nv_dma_sync(dma_dev, priv, NV_OS_DMA_SYNC_FROM_DEVICE);
}

"""

NV_PCI_C_HOOK = "    nv_arm_note_device(nv);\n"

NV_C_POLICY = r"""/*
 * M10/RK3588 port: non-coherent Arm policy.
 *
 * The proprietary RM marks every non-Tegra chipset as I/O coherent and, on
 * aarch64, then upgrades all system memory allocations to NV_MEMORY_CACHED.
 * On PCIe hosts that don't snoop CPU caches (e.g. RK3588) that corrupts data.
 * We can't fix the RM's decision without binary patching, but every system
 * memory allocation flows through nv_alloc_pages(), and at->cache_type drives
 * all kernel/user mappings of it - so downgrade CACHED to UNCACHED there.
 */
static int nv_arm_force_uncached = 1;
module_param_named(arm_force_uncached, nv_arm_force_uncached, int, 0444);
MODULE_PARM_DESC(arm_force_uncached,
    "arm64: map RM system memory uncached on non-DMA-coherent hosts (default 1)");

static int nv_arm_disable_wc = 1;
module_param_named(arm_disable_iomap_wc, nv_arm_disable_wc, int, 0444);
MODULE_PARM_DESC(arm_disable_iomap_wc,
    "arm64: never map GPU BARs write-combined (default 1)");

static int nv_arm_assume_noncoherent = -1;
module_param_named(arm_assume_noncoherent, nv_arm_assume_noncoherent, int, 0444);
MODULE_PARM_DESC(arm_assume_noncoherent,
    "arm64: -1 = ask the kernel (default), 0 = coherent, 1 = non-coherent");

static NvBool nv_arm_any_noncoherent_dev = NV_FALSE;
static atomic_t nv_arm_forced_allocs = ATOMIC_INIT(0);

NvBool nv_arm_is_noncoherent(nv_state_t *nv)
{
#if defined(NVCPU_AARCH64)
    if (nv_arm_assume_noncoherent >= 0)
        return nv_arm_assume_noncoherent ? NV_TRUE : NV_FALSE;
    if ((nv != NULL) && (nv->dma_dev != NULL) && (nv->dma_dev->dev != NULL))
        return !nv_dev_is_dma_coherent(nv->dma_dev);
    return nv_arm_any_noncoherent_dev;
#else
    return NV_FALSE;
#endif
}

void nv_arm_note_device(nv_state_t *nv)
{
#if defined(NVCPU_AARCH64)
    NvBool nc = nv_arm_is_noncoherent(nv);
    if (nc)
        nv_arm_any_noncoherent_dev = NV_TRUE;
    nv_printf(NV_DBG_ERRORS,
        "NVRM: arm64: %04x:%02x:%02x: DMA %s; sysmem %s, BAR WC %s\n",
        nv->pci_info.domain, nv->pci_info.bus, nv->pci_info.slot,
        nc ? "NON-coherent" : "coherent",
        (nc && nv_arm_force_uncached) ? "forced uncached" : "as requested by RM",
        nv_arm_disable_iomap_wc() ? "off" : "on");
#endif
}

NvBool nv_arm_disable_iomap_wc(void)
{
#if defined(NVCPU_AARCH64)
    if (nv_arm_disable_wc)
        return NV_TRUE;
#endif
    return rm_disable_iomap_wc();
}

"""

NV_C_OVERRIDE = r"""#if defined(NVCPU_AARCH64)
    /* M10/RK3588 port: see nv_arm_is_noncoherent() */
    if (nv_arm_force_uncached &&
        (cache_type == NV_MEMORY_CACHED) &&
        nv_arm_is_noncoherent(nv))
    {
        cache_type = NV_MEMORY_UNCACHED;
        if (atomic_inc_return(&nv_arm_forced_allocs) == 1)
            nv_printf(NV_DBG_ERRORS,
                "NVRM: arm64: forcing RM sysmem allocations uncached "
                "(non-coherent DMA)\n");
    }
#endif

"""

# ---------------------------------------------------------------------------
# Edit operations: (file, kind, anchor, payload)
#   insert_before / insert_after: anchor must occur exactly once
#   replace: anchor must occur exactly once, replaced by payload
#   insert_before_in_func: (func_anchor, anchor) - first anchor after func
# ---------------------------------------------------------------------------

EDITS = [
    ("common/inc/nv.h", "insert_after",
     "NvBool     NV_API_CALL  nv_dev_is_dma_coherent   (nv_dma_device_t *);\n",
     NV_H_DECLS),
    ("common/inc/os-interface.h", "insert_before",
     "void        NV_API_CALL  os_flush_cpu_write_combine_buffer",
     OS_INTERFACE_H_DECLS),
    ("nvidia/os-interface.c", "insert_before",
     "void NV_API_CALL os_flush_cpu_write_combine_buffer(void)\n",
     OS_INTERFACE_C_SHIMS),
    ("nvidia/os-interface.c", "replace",
     "vaddr = rm_disable_iomap_wc() ?",
     "vaddr = nv_arm_disable_iomap_wc() ?"),
    ("nvidia/nv-mmap.c", "replace",
     "rm_disable_iomap_wc() ? NV_MEMORY_UNCACHED",
     "nv_arm_disable_iomap_wc() ? NV_MEMORY_UNCACHED"),
    ("nvidia/nv-dma.c", "insert_before",
     "NvBool NV_API_CALL nv_dev_is_dma_coherent\n",
     NV_DMA_C_SHIM),
    # After pci_info is filled in, so the log line shows the right address.
    ("nvidia/nv-pci.c", "insert_after",
     "    nv->pci_info.slot      = NV_PCI_SLOT_NUMBER(pci_dev);\n",
     NV_PCI_C_HOOK),
    ("nvidia/nv.c", "insert_before",
     "NV_STATUS NV_API_CALL nv_alloc_pages(\n",
     NV_C_POLICY),
    ("nvidia/nv.c", "insert_before_in_func",
     ("NV_STATUS NV_API_CALL nv_alloc_pages(\n",
      "    at = nvos_create_alloc(dev, page_count);\n"),
     NV_C_OVERRIDE),
]

# Files that must show the upstream non-coherent-arm-fixes before we apply.
UPSTREAM_SIGNS = {
    "common/inc/nv.h": "nv_dev_is_dma_coherent",
    "nvidia/nv-dma.c": "void NV_API_CALL nv_dma_sync",
}


def die(msg):
    print("m10-patcher: error: " + msg, file=sys.stderr)
    sys.exit(1)


def read(root, rel):
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        die("missing %s - is this a 580.95.05 aarch64 'kernel' directory?" % path)
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write(root, rel, text):
    with open(os.path.join(root, rel), "w", encoding="utf-8",
              errors="surrogateescape") as f:
        f.write(text)


def cmd_verify_stock(root):
    bad = []
    for rel, want in sorted(STOCK_SHA256.items()):
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            die("missing %s - is this a 580.95.05 aarch64 'kernel' directory?" % path)
        with open(path, "rb") as f:
            got = hashlib.sha256(f.read()).hexdigest()
        if got != want:
            bad.append(rel)
    if bad:
        die("these files don't match stock 580.95.05 aarch64: " + ", ".join(bad))
    print("m10-patcher: stock 580.95.05 aarch64 sources verified")


def is_applied(root):
    return MARKER in read(root, "nvidia/nv.c")


def cmd_check(root):
    print("applied" if is_applied(root) else "not applied")


def apply_edit(text, kind, anchor, payload, rel):
    if kind == "insert_before_in_func":
        func, inner = anchor
        if text.count(func) != 1:
            die("%s: function anchor found %d times" % (rel, text.count(func)))
        fpos = text.index(func)
        ipos = text.find(inner, fpos)
        if ipos < 0:
            die("%s: inner anchor not found after function anchor" % rel)
        return text[:ipos] + payload + text[ipos:]

    n = text.count(anchor)
    if n != 1:
        die("%s: anchor %r found %d times (expected 1)" % (rel, anchor[:50], n))
    if kind == "insert_before":
        return text.replace(anchor, payload + anchor)
    if kind == "insert_after":
        return text.replace(anchor, anchor + payload)
    if kind == "replace":
        return text.replace(anchor, payload)
    die("unknown edit kind " + kind)


def cmd_apply(root):
    if is_applied(root):
        print("m10-patcher: already applied, nothing to do")
        return
    for rel, sign in UPSTREAM_SIGNS.items():
        if sign not in read(root, rel):
            die("%s lacks upstream non-coherent-arm-fixes; "
                "run scripts/fetch-upstream-fixes.sh first" % rel)

    # Apply all edits in memory first so a failure leaves the tree untouched.
    files = {}
    for rel, kind, anchor, payload in EDITS:
        if rel not in files:
            files[rel] = read(root, rel)
        files[rel] = apply_edit(files[rel], kind, anchor, payload, rel)
    for rel, text in files.items():
        write(root, rel, text)
        print("m10-patcher: patched " + rel)
    print("m10-patcher: done")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("verify-stock", "apply", "check"):
        print("usage: %s {verify-stock|apply|check} <driver>/kernel" % sys.argv[0],
              file=sys.stderr)
        sys.exit(2)
    root = sys.argv[2]
    {"verify-stock": cmd_verify_stock, "apply": cmd_apply,
     "check": cmd_check}[sys.argv[1]](root)


if __name__ == "__main__":
    main()
