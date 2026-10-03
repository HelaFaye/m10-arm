# m10-arm — Tesla M10 on Orange Pi 5 Plus (RK3588)

> [!WARNING]
> **UNTESTED WORK IN PROGRESS.** None of this has run on real hardware yet.
> It compiles against Linux 6.18 arm64, and that is all that has been verified.
> It loads a patched kernel module that can hang, crash or corrupt your
> system. Use at your own risk, on a machine you can recover.

Patch scripts that let NVIDIA's own **580.95.05 aarch64** driver run a
**Tesla M10** (4× Maxwell GM107, `10de:13bd`) on an **RK3588** board, whose
PCIe is not cache-coherent with the CPU. They also set up CUDA 12.9.

**This repository contains no NVIDIA code.** You supply NVIDIA's installer
yourself: `NVIDIA-Linux-aarch64-580.95.05.run`. The scripts verify it's that
exact version, then patch the kernel-interface sources inside it on your
machine.

## Why it's needed

- Maxwell GPUs need NVIDIA's **proprietary** kernel module. The open module only supports Turing and newer.
- The driver's closed core treats every non-Tegra platform as I/O-coherent. On aarch64 it then makes all system memory shared with the GPU **cached**. On RK3588 the GPU can't see the CPU caches, so data goes stale silently.
- On arm64 the driver's "flush the whole CPU cache" fallback is a no-op: the kernel API it needs was removed in Linux 4.2.

## What the scripts do

1. **`scripts/fetch-upstream-fixes.sh`** downloads Mario Bălănică's
   [`non-coherent-arm-fixes`](https://github.com/mariobalanica/open-gpu-kernel-modules/tree/non-coherent-arm-fixes)
   for NVIDIA's open kernel modules, pinned to exact commit IDs. It applies only the
   `kernel-open/` part (real DMA cache maintenance) to the proprietary
   module's C sources. That work is downloaded at install time and is not included here.
2. **`patcher/m10_arm_patcher.py`** adds this project's changes:
   - Restores three functions the closed core still calls (`os_flush_cpu_cache_all`,
     `os_flush_user_cache`, `nv_dma_cache_invalidate`). The last now really invalidates.
   - When the kernel reports the GPU's DMA as non-coherent, it maps all
     driver-allocated system memory **uncached** (Normal-NC) instead of cached.
   - Cleans the CPU cache over each new uncached allocation, so dirty lines
     left from zeroing it can't later overwrite data the GPU or CPU wrote.
   - Refuses `cudaHostRegister` (registering ordinary process memory) on
     non-coherent hosts. The process's own cached mapping of that memory
     can't be changed, so it would silently corrupt data.
   - Turns off write-combined mappings of the GPU's PCIe memory windows on arm64.
   - In `nvidia-uvm`, maps managed memory (`cudaMallocManaged`) and UVM's own
     system memory uncached too. UVM maps these itself, so the main fix above
     doesn't reach them. It also cleans the CPU cache around UVM's own CPU-side
     copies and its CPU writes to GPU page tables in system memory.
3. **`scripts/install.sh`** extracts your `.run`, verifies it, runs steps 1–2, then runs
   NVIDIA's installer with display/GL parts disabled. Your desktop stays on the
   board's Mali GPU, and the M10 is used for compute only.
4. **`scripts/setup-cuda.sh`** installs the CUDA 12.9 toolkit (the last version that supports
   Maxwell) and runs `tests/m10_cuda_selftest.cu`.

### Module parameters (`options nvidia ...` in `/etc/modprobe.d/`)

| Parameter | Default | Meaning |
|---|---|---|
| `arm_force_uncached` | `1` | Uncached system memory on non-coherent hosts. `0` = stock behaviour. |
| `arm_disable_iomap_wc` | `1` | Never map GPU memory windows write-combined. |
| `arm_assume_noncoherent` | `-1` | `-1` ask the kernel, `1` force non-coherent, `0` force coherent. |
| `arm_allow_host_register` | `0` | `1` = allow `cudaHostRegister` on non-coherent hosts anyway (can corrupt data). |

`nvidia-uvm` has one (`options nvidia-uvm ...`):

| Parameter | Default | Meaning |
|---|---|---|
| `uvm_arm_uncached_sysmem` | `1` | Uncached managed/UVM system memory on non-coherent hosts. `0` = stock behaviour. |

If CUDA fails to start and `dmesg` shows `refusing to register user memory`,
something besides `cudaHostRegister` needs that path: set
`arm_allow_host_register=1` and report it in an issue.

## Tested so far

| | Status |
|---|---|
| Patches apply to stock 580.95.05 aarch64 | ✅ (sha256-verified input) |
| Module builds against Linux 6.18.52 arm64 | ✅ cross-compiled (before the host-register, cache-clean and UVM changes) |
| Current patches compile against Linux 6.18 arm64 | ⚠️ only on NVIDIA's open-module sources at the same version, as a stand-in |
| All functions the closed core imports resolve | ✅ |
| CUDA self-test compiles for sm_50 | ✅ (CUDA 12.9 `ptxas`) |
| Loads on an Orange Pi 5 Plus | ❌ not yet tried |
| `nvidia-smi` sees 4× M10 | ❌ not yet tried |
| CUDA self-test passes | ❌ not yet tried |

## Requirements

- Orange Pi 5 Plus (RK3588) with Armbian Noble (Ubuntu 24.04 base), tested
  build target: kernel 6.18.x
- Tesla M10 on a PCIe adapter, with external 8-pin power and **forced airflow** (the card has no fan)
- Kernel headers for your running kernel, `build-essential`, `git`, `patch`, `python3`
- `NVIDIA-Linux-aarch64-580.95.05.run` from NVIDIA (not included)

## Usage

```sh
git clone https://github.com/HelaFaye/m10-arm && cd m10-arm

# 0. Is the hardware visible with all BARs assigned?
sudo scripts/check-pcie.sh

# 1. Patch + install the driver
sudo apt install build-essential git patch python3 linux-headers-<your-armbian-kernel-flavour>
sudo scripts/install.sh ~/Downloads/NVIDIA-Linux-aarch64-580.95.05.run
sudo update-initramfs -u && sudo reboot

# 2. Check it
sudo modprobe nvidia nvidia-uvm
sudo dmesg | grep -E 'NVRM|nvidia'   # expect: "DMA NON-coherent; sysmem forced uncached"
nvidia-smi

# 3. CUDA toolkit + self-test
sudo scripts/setup-cuda.sh
```

To only produce a patched driver tree without installing anything:
`scripts/install.sh --patch-only <file.run>`.

### Using CUDA

The driver's `libcuda` and `nvidia-uvm` come from your `.run`. Use **CUDA 12.9**:
13.x can't build for Maxwell. For llama.cpp:

```sh
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=50 && cmake --build build -j8
```

## Known risks

- **PCIe BAR space.** RK3588 PCIe windows are small. Four GPUs plus a switch may not get
  their BARs assigned. `check-pcie.sh` reports it, and fixing it needs device-tree changes.
- **Atomics on uncached memory** may not work on RK3588. A hang, SError or alignment fault
  after init points here. The self-test's "atomics in mapped host memory" line is
  informational only: CUDA doesn't promise those atomics on Maxwell over PCIe even on x86.
  The next step would be targeted fixes inside the closed core instead of forcing everything uncached.
  This now includes CPU-side atomics in programs using `cudaMallocManaged` memory.
- **Cache maintenance cost.** The driver now cleans the CPU cache by address
  (`dc civac`) over every new uncached allocation and over every page UVM maps for
  a GPU. That's independent of swiotlb and the IOMMU, but large allocations take
  longer to set up.
- **Performance** is modest: each GM107 has 8 GB at ~83 GB/s, no fast FP16 and no `dp4a`.

## Reporting results

Please open an issue with: `sudo scripts/check-pcie.sh`, full `sudo dmesg` after
`modprobe nvidia`, `nvidia-smi -q`, and the self-test output.

## Credits

By [HelaFaye](https://github.com/HelaFaye). Built on Mario Bălănică's
[non-coherent-arm-fixes](https://github.com/mariobalanica/open-gpu-kernel-modules/tree/non-coherent-arm-fixes)
and NVIDIA's [open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules).
See [`CREDITS.md`](CREDITS.md) for details.

## License

The scripts and patcher in this repository are MIT (see `LICENSE`). NVIDIA's
driver is NVIDIA's software under NVIDIA's license, and is not distributed here.
The upstream fixes fetched at install time are © their authors under the
open-gpu-kernel-modules license (MIT/GPLv2).
