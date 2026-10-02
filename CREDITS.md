# Credits

## Author

- **HelaFaye** ([@HelaFaye](https://github.com/HelaFaye)): this project: the
  proprietary-module patcher, install/CUDA scripts and CUDA self-test.

## Upstream work this project uses or builds on

- **Mario Bălănică** ([@mariobalanica](https://github.com/mariobalanica)) wrote
  [`non-coherent-arm-fixes`](https://github.com/mariobalanica/open-gpu-kernel-modules/tree/non-coherent-arm-fixes)
  for NVIDIA's open GPU kernel modules, which made NVIDIA GPUs work on
  RK3588 and Raspberry Pi 5.
  - `scripts/fetch-upstream-fixes.sh` downloads and applies his `kernel-open/`
    changes at install time: commits `ac7630d`, `95bc81d`, `9861907`, `492cb52`
    and `1007273`, on top of `2b43605` (580.95.05).
  - The patcher's approach follows his analysis and fixes. It forces
    non-coherent system memory uncached (his `1007273`), disables
    write-combined BAR mappings (his `95bc81d`), and builds the restored
    `nv_dma_cache_invalidate()` on his `nv_dma_sync()` helper (`492cb52`).
    This project re-implements those ideas in the C layer, because Maxwell
    GPUs require NVIDIA's closed kernel module, which his open-module patches
    can't change.
  - License: MIT / GPLv2, as for open-gpu-kernel-modules.

- **NVIDIA Corporation**: [open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
  (MIT / GPLv2). Its source was used to understand the driver internals that
  the patcher targets, and it is the base of the upstream fixes above. The
  NVIDIA driver itself is NVIDIA's proprietary software. It is **not**
  distributed here; users supply their own `.run` installer.

## Acknowledgements

- [Jeff Geerling](https://www.jeffgeerling.com/blog/2025/nvidia-graphics-cards-work-on-pi-5-and-rockchip/)
  documented NVIDIA GPUs on Pi 5 and Rockchip, which pointed to the upstream fixes.
