# Proxmox on RK3588 with a Tesla M10

> [!WARNING]
> **Untested**, like the rest of this repository. Get the M10 working on the
> host first (README → Usage). A container only adds the device sharing on top.

**Short version:** run Proxmox on the board, load the patched `nvidia` module
**on the host**, and give the M10's device nodes to an **LXC container** with
Proxmox's `devN:` option. The container gets only NVIDIA's user-space
libraries. A VM with the GPU passed through (VFIO) can't work on RK3588.

## Why not a VM

The kernel hands a device to VFIO only if its IOMMU reports
`IOMMU_CAP_CACHE_COHERENCY`, and refuses with `-EINVAL` otherwise
(`drivers/vfio/vfio_main.c`). RK3588's PCIe SMMU isn't coherent, so no
Proxmox version or VM option gets past that.

It's also the problem this repository works around: the M10 can't see the CPU
caches. That has to be handled in the kernel module, so the module must run on
the host anyway. Containers share the host kernel, so they use the patched
module directly, need no VFIO, and have no virtualisation overhead.

## Which Proxmox

The two routes are the same as for the MI50 in the companion mi50-arm guide:
- the official **Proxmox VE 9.2 arm64**, which needs UEFI (edk2-rk3588) and doesn't support single-board computers;
- the community port **PXVirt**, on top of Armbian.

The difference for the M10 is the kernel:
- `scripts/install.sh` builds the patched module against the running kernel's headers
  (`/lib/modules/$(uname -r)/build`). On the official route, install the
  `proxmox-headers-*` package that matches your `proxmox-kernel-*`.
- The module has only been built against Linux 6.18.52. The official Proxmox
  arm64 kernel is 7.0, which is untried. **PXVirt on Armbian with a 6.18 kernel
  is the safer route** until `install.sh` is known to build against 7.0.
- **Pin the kernel** (`proxmox-boot-tool kernel pin <version>`, or hold the Armbian
  kernel packages). A kernel update without a rebuilt module leaves the host with
  no `nvidia` module, and the container with no GPU.

## Host setup

1. Install the driver as in the README (`check-pcie.sh`, then `install.sh`, then
   reboot), and check that `nvidia-smi` on the host lists four GPUs.
2. Load the modules at boot, and create the device nodes before any container
   starts. `/dev/nvidia-uvm` only appears once something uses CUDA, and a
   container can't create it.

   ```sh
   printf 'nvidia\nnvidia-uvm\n' | sudo tee /etc/modules-load.d/nvidia-m10.conf
   sudo tee /etc/systemd/system/nvidia-nodes.service >/dev/null <<'U'
   [Unit]
   Description=Create NVIDIA device nodes for containers
   After=systemd-modules-load.service
   Before=pve-guests.service

   [Service]
   Type=oneshot
   ExecStart=/usr/bin/nvidia-modprobe -u -c=0
   ExecStart=/usr/bin/nvidia-smi -L
   RemainAfterExit=yes

   [Install]
   WantedBy=multi-user.target
   U
   sudo systemctl enable --now nvidia-nodes.service
   ls -l /dev/nvidia*
   ```

   `nvidia-modprobe` comes from NVIDIA's `.run`. Expect `nvidia0`–`nvidia3`,
   `nvidiactl`, `nvidia-uvm` and `nvidia-uvm-tools`.
3. Optionally, turn on persistence mode so the four GPUs stay initialised
   between jobs: `sudo nvidia-smi -pm 1`.

## Container setup

Create an **Ubuntu 24.04 arm64** container (for example, ID 102).
`setup-cuda.sh` uses NVIDIA's `ubuntu2404/sbsa` repository, so another distribution needs another repository.

Pass every node through. NVIDIA's nodes are world-readable and writable
(mode 0666) on the host, so no `gid=` is needed:

```sh
pct set 102 -dev0 /dev/nvidia0
pct set 102 -dev1 /dev/nvidia1
pct set 102 -dev2 /dev/nvidia2
pct set 102 -dev3 /dev/nvidia3
pct set 102 -dev4 /dev/nvidiactl
pct set 102 -dev5 /dev/nvidia-uvm
pct set 102 -dev6 /dev/nvidia-uvm-tools
```

Only `root@pam` may add device passthrough. To keep the container on the A76
cores, add this line to `/etc/pve/lxc/102.conf`:

```
lxc.cgroup2.cpuset.cpus: 4-7
```

Inside the container, install NVIDIA's user-space libraries **at exactly the
host's version**, without a kernel module:
- `libcuda` and the kernel module talk through a private interface, so a version mismatch fails at `cuInit`.
- The patches here change only the kernel-interface sources, so the container uses the stock, unpatched `.run`.

```sh
sh NVIDIA-Linux-aarch64-580.95.05.run --no-kernel-module --no-opengl-files --no-drm \
    --no-x-check --ui=none --no-questions --accept-license
nvidia-smi                      # four GPUs
```

Then the CUDA toolkit and the self-test, from a copy of this repository inside
the container:

```sh
sudo scripts/setup-cuda.sh      # toolkit only; its apt pin keeps driver packages out
```

The self-test running in the container exercises the same patched host
module, so a pass there means the sharing works too.

## What can go wrong

- **`nvidia-smi` fails in the container but works on the host:** the user-space
  version differs from the host's module (`cat /proc/driver/nvidia/version` on
  the host), or a node is missing from the `devN` list.
- **`cuInit` returns 999 or CUDA sees no devices:** `/dev/nvidia-uvm` was missing
  when the container started. Check the systemd unit, then restart the container.
- **The container works until a kernel update:** the module wasn't rebuilt for the
  new kernel. Pin the kernel, and rerun `install.sh` deliberately when you do update.
- **Hangs or SErrors under load:** these are the same risks as on the bare host (README →
  Known risks). The container doesn't add or remove any.
