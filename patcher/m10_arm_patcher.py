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
    # nvidia-uvm is open source in both the proprietary and open packages.
    # These hashes come from NVIDIA's open-gpu-kernel-modules at 580.95.05
    # (commit 2b43605): six of the nine files above match that release
    # byte for byte, and the three that don't carry proprietary-only code.
    "nvidia-uvm/uvm_gpu.c":            "149d4c343e3cc945132d209ef7bba0018dcd483ef60e4cf8ad46ddec025c0a25",
    "nvidia-uvm/uvm_gpu.h":            "d30552079c49fc4ab5a2e437e8289ae3bc648a61a92a667c7c92d06f8f29633d",
    "nvidia-uvm/uvm_mem.c":            "e98ce17dd9902f5a8b6cf8fb3919b3e85a4f82814029011af64c6e287a1d84d2",
    "nvidia-uvm/uvm_mmu.c":            "e8451e8801c06d6ccafdb44f1c2540ea3c68703f7d2516584fac85324f1806d7",
    "nvidia-uvm/uvm_pmm_sysmem.c":     "83d371c8395a5e1e36a18c8efcb0d9dabd93e4a6e29e7a0651aad4c4ba9e5932",
    "nvidia-uvm/uvm_va_block.c":       "a9d219c0909246e680e33f4201823717a6383972adf92a79df28e43782ad66f5",
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

static int nv_arm_allow_host_register = 0;
module_param_named(arm_allow_host_register, nv_arm_allow_host_register, int, 0444);
MODULE_PARM_DESC(arm_allow_host_register,
    "arm64: allow registering user memory (cudaHostRegister) on "
    "non-DMA-coherent hosts, where it can silently corrupt data (default 0)");

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

/*
 * Clean and invalidate [va, va + size) to the point of coherency with
 * "dc civac", like the kernel's dcache_clean_inval_poc() (not exported).
 * Doing it by address doesn't depend on a device, an IOMMU or swiotlb, any
 * of which can make DMA-API cache maintenance miss the real pages. The
 * stride is the smallest D-cache line this CPU reports, capped at 64 bytes
 * so a big.LITTLE mix of line sizes can't make it skip lines.
 */
static void nv_arm_cpu_cache_flush(const void *va, size_t size)
{
#if defined(NVCPU_AARCH64)
    unsigned long line = 4UL << ((read_cpuid_cachetype() >> 16) & 0xf);
    unsigned long p, end = (unsigned long)va + size;

    if (line > 64)
        line = 64;
    for (p = (unsigned long)va & ~(line - 1); p < end; p += line)
        asm volatile("dc civac, %0" : : "r" (p) : "memory");
    dsb(sy);
#endif
}

/*
 * Write back the CPU cache lines covering a new uncached allocation. Its pages
 * were just zeroed (or last used) through the kernel's cacheable linear map.
 * If those dirty lines were evicted later, they would overwrite data already
 * written through the uncached alias.
 */
static void nv_arm_clean_alloc(nv_alloc_t *at)
{
    NvU64 i;

    /* dma_alloc_coherent() memory is already handled by the kernel */
    if (at->flags.coherent)
        return;

    for (i = 0; i < at->num_pages; i++)
        nv_arm_cpu_cache_flush(phys_to_virt(at->page_table[i].phys_addr), PAGE_SIZE);
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

NV_C_CLEAN = r"""#if defined(NVCPU_AARCH64)
    /* M10/RK3588 port: see nv_arm_clean_alloc() */
    if ((at->cache_type != NV_MEMORY_CACHED) && nv_arm_is_noncoherent(nv))
        nv_arm_clean_alloc(at);
#endif

"""

NV_C_HOST_REGISTER = r"""#if defined(NVCPU_AARCH64)
    /*
     * M10/RK3588 port: the process keeps its own cacheable mapping of these
     * pages, which we can't change, and the RM does no cache maintenance for
     * them. On a non-coherent host the GPU would then see stale data (and the
     * CPU stale GPU writes). Refuse instead of corrupting data silently.
     */
    if (!nv_arm_allow_host_register && nv_arm_is_noncoherent(nv))
    {
        printk_once(KERN_INFO "NVRM: arm64: refusing to register user memory "
                    "(e.g. cudaHostRegister) on a non-coherent host; "
                    "nvidia.arm_allow_host_register=1 overrides\n");
        return NV_ERR_NOT_SUPPORTED;
    }
#endif

"""

# nvidia-uvm: managed memory and UVM's own sysmem are mapped by UVM itself,
# not through nv_alloc_pages(), so they need the same treatment there.
UVM_GPU_C_POLICY = r"""/*
 * M10/RK3588 port: non-coherent Arm policy for UVM.
 *
 * UVM maps managed memory (cudaMallocManaged) and its own system memory
 * cacheable for the CPU and does no cache maintenance, assuming the GPU snoops
 * CPU caches. On hosts where it doesn't (e.g. RK3588), map them uncached
 * (Normal-NC) instead, as nvidia.ko does for RM memory. Pages are cleaned
 * from the CPU cache when allocated and when mapped for a GPU, and around the
 * kernel's own cached copies (uvm_arm_cpu_cache_flush()).
 */
#if defined(NVCPU_AARCH64) && defined(NV_DEV_IS_DMA_COHERENT_PRESENT)
#include <linux/dma-map-ops.h>
#endif

static int uvm_arm_uncached_sysmem = 1;
module_param(uvm_arm_uncached_sysmem, int, S_IRUGO);
MODULE_PARM_DESC(uvm_arm_uncached_sysmem,
    "arm64: map UVM system memory uncached on non-DMA-coherent hosts (default 1)");

static bool uvm_arm_any_noncoherent;

bool uvm_arm_noncoherent(void)
{
    return READ_ONCE(uvm_arm_any_noncoherent);
}

bool uvm_arm_sysmem_uncached(void)
{
    return uvm_arm_uncached_sysmem && uvm_arm_noncoherent();
}

// Clean and invalidate [va, va + size) to the point of coherency, like the
// kernel's dcache_clean_inval_poc() (not exported). By address, so it doesn't
// depend on swiotlb or an IOMMU. No-op on coherent hosts. The stride is capped
// at 64 bytes so a big.LITTLE mix of line sizes can't make it skip lines.
void uvm_arm_cpu_cache_flush(const void *va, size_t size)
{
#if defined(NVCPU_AARCH64)
    unsigned long line = 4UL << ((read_cpuid_cachetype() >> 16) & 0xf);
    unsigned long p, end = (unsigned long)va + size;

    if (!uvm_arm_noncoherent())
        return;
    if (line > 64)
        line = 64;
    for (p = (unsigned long)va & ~(line - 1); p < end; p += line)
        asm volatile("dc civac, %0" : : "r" (p) : "memory");
    dsb(sy);
#endif
}

static void uvm_arm_note_parent_gpu(uvm_parent_gpu_t *parent_gpu)
{
#if defined(NVCPU_AARCH64) && defined(NV_DEV_IS_DMA_COHERENT_PRESENT)
    if ((parent_gpu->pci_dev != NULL) && !dev_is_dma_coherent(&parent_gpu->pci_dev->dev)) {
        WRITE_ONCE(uvm_arm_any_noncoherent, true);
        pr_info("nvidia-uvm: arm64: %s: DMA NON-coherent; UVM sysmem %s\n",
                pci_name(parent_gpu->pci_dev),
                uvm_arm_uncached_sysmem ? "mapped uncached" : "left cached");
    }
#endif
}

"""

UVM_GPU_H_DECL = """// M10/RK3588 port: non-coherent Arm helpers (uvm_gpu.c)
bool uvm_arm_noncoherent(void);
bool uvm_arm_sysmem_uncached(void);
void uvm_arm_cpu_cache_flush(const void *va, size_t size);

"""

UVM_PGPROT_FIX = r"""#if defined(NVCPU_AARCH64)
    // M10/RK3588 port: see uvm_arm_sysmem_uncached()
    if (uvm_arm_sysmem_uncached())
        target_pgprot = pgprot_writecombine(target_pgprot);
#endif
"""

UVM_MEM_KERNEL_FIX = r"""#if defined(NVCPU_AARCH64)
    // M10/RK3588 port: see uvm_arm_sysmem_uncached()
    if (uvm_arm_sysmem_uncached())
        prot = pgprot_writecombine(prot);
#endif

"""

UVM_MEM_USER_FIX = r"""#if defined(NVCPU_AARCH64)
    // M10/RK3588 port: see uvm_arm_sysmem_uncached()
    if (uvm_arm_sysmem_uncached())
        vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
#endif

"""

UVM_MAP_FLUSH = r"""    // M10/RK3588 port: write back/discard CPU cache lines for pages the GPU
    // is about to access directly (see uvm_arm_cpu_cache_flush())
    uvm_arm_cpu_cache_flush(page_address(page), size);

"""

UVM_CHUNK_ALLOC_FLUSH = r"""        // M10/RK3588 port: don't leave dirty lines from zeroing behind
        uvm_arm_cpu_cache_flush(page_address(page), alloc_size);
"""

# CPU-to-CPU page copy: drop stale lines before reading, write back after.
UVM_CPU_COPY = r"""            uvm_arm_cpu_cache_flush(src_addr, PAGE_SIZE);   // M10/RK3588 port
            memcpy(dst_addr, src_addr, PAGE_SIZE);
            uvm_arm_cpu_cache_flush(dst_addr, PAGE_SIZE);
"""

UVM_WRITE_FROM_CPU = r"""        memcpy(mapped_page + page_offset, src, size);
        uvm_arm_cpu_cache_flush(mapped_page + page_offset, size);   // M10/RK3588 port
"""

UVM_READ_TO_CPU = r"""        uvm_arm_cpu_cache_flush(mapped_page + page_offset, size);   // M10/RK3588 port
        memcpy(dst, mapped_page + page_offset, size);
"""

# GPU page tables in sysmem written by the CPU must reach RAM before the GPU
# walks them.
UVM_PT_UNMAP = r"""    else {
        // M10/RK3588 port: see uvm_arm_cpu_cache_flush()
        if (phys_alloc->addr.aperture == UVM_APERTURE_SYS)
            uvm_arm_cpu_cache_flush((void *)((unsigned long)ptr & PAGE_MASK), PAGE_SIZE);
        kunmap(uvm_mmu_page_table_page(gpu, phys_alloc));
    }
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
    # Before nv_register_user_pages(), the first function that uses it.
    ("nvidia/nv.c", "insert_before",
     "NV_STATUS NV_API_CALL nv_register_user_pages(\n",
     NV_C_POLICY),
    ("nvidia/nv.c", "insert_before_in_func",
     ("NV_STATUS NV_API_CALL nv_register_user_pages(\n",
      "    at = nvos_create_alloc(nvl->dev, page_count);\n"),
     NV_C_HOST_REGISTER),
    ("nvidia/nv.c", "insert_before_in_func",
     ("NV_STATUS NV_API_CALL nv_alloc_pages(\n",
      "    at = nvos_create_alloc(dev, page_count);\n"),
     NV_C_OVERRIDE),
    ("nvidia/nv.c", "insert_before_in_func",
     ("NV_STATUS NV_API_CALL nv_alloc_pages(\n",
      "    for (i = 0; i < ((contiguous) ? 1 : page_count); i++)\n"),
     NV_C_CLEAN),
    ("nvidia-uvm/uvm_gpu.h", "insert_before",
     "static bool uvm_parent_gpu_is_coherent(",
     UVM_GPU_H_DECL),
    ("nvidia-uvm/uvm_gpu.c", "insert_before",
     "static NV_STATUS init_parent_gpu(uvm_parent_gpu_t *parent_gpu,\n",
     UVM_GPU_C_POLICY),
    ("nvidia-uvm/uvm_gpu.c", "insert_after",
     "    parent_gpu->pci_dev = gpu_platform_info->pci_dev;\n",
     "    uvm_arm_note_parent_gpu(parent_gpu);\n"),
    ("nvidia-uvm/uvm_va_block.c", "insert_after",
     "    target_pgprot = vm_get_page_prot(target_flags);\n",
     UVM_PGPROT_FIX),
    ("nvidia-uvm/uvm_mem.c", "insert_before",
     "    mem->kernel.cpu_addr = vmap(pages, num_pages, VM_MAP, prot);\n",
     UVM_MEM_KERNEL_FIX),
    ("nvidia-uvm/uvm_mem.c", "insert_before",
     "    for (offset = 0; offset < uvm_mem_physical_size(mem); offset += PAGE_SIZE) {\n"
     "        int ret = vm_insert_page(",
     UVM_MEM_USER_FIX),
    ("nvidia-uvm/uvm_gpu.c", "insert_before",
     "    dma_addr = dma_map_page(&parent_gpu->pci_dev->dev, page, 0, size, DMA_BIDIRECTIONAL);\n",
     UVM_MAP_FLUSH),
    ("nvidia-uvm/uvm_pmm_sysmem.c", "insert_after",
     "        if (alloc_flags & UVM_CPU_CHUNK_ALLOC_FLAGS_ZERO)\n"
     "            SetPageDirty(page);\n",
     UVM_CHUNK_ALLOC_FLUSH),
    ("nvidia-uvm/uvm_va_block.c", "replace",
     "            memcpy(dst_addr, src_addr, PAGE_SIZE);\n",
     UVM_CPU_COPY),
    ("nvidia-uvm/uvm_va_block.c", "replace",
     "        memcpy(mapped_page + page_offset, src, size);\n",
     UVM_WRITE_FROM_CPU),
    ("nvidia-uvm/uvm_va_block.c", "replace",
     "        memcpy(dst, mapped_page + page_offset, size);\n",
     UVM_READ_TO_CPU),
    ("nvidia-uvm/uvm_mmu.c", "replace",
     "    else\n"
     "        kunmap(uvm_mmu_page_table_page(gpu, phys_alloc));\n",
     UVM_PT_UNMAP),
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
        if all(rel.startswith("nvidia-uvm/") for rel in bad):
            die("these nvidia-uvm files don't match the open 580.95.05 release "
                "their hashes were taken from; please report them in an issue: "
                + ", ".join(bad))
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
