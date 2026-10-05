#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# torch_selftest.py - PyTorch correctness test for the Tesla M10 on a
# non-cache-coherent Arm host. Like m10_cuda_selftest.cu, it uses fresh data
# every round so stale caches show up as wrong results, and compares GPU
# results with the CPU.
#
# *** UNTESTED WORK IN PROGRESS. ***
#
#   python tests/torch_selftest.py [--rounds N] [--expect-gpus N]

import argparse
import sys

import torch
import torch.nn.functional as F

failures = 0


def report(name, ok, detail=""):
    global failures
    if not ok:
        failures += 1
    print("    %-38s %s%s" % (name, "ok" if ok else "FAIL", ("  (" + detail + ")") if detail else ""))


def close(name, got, want, rtol=1e-3, atol=1e-3):
    got = got.float().cpu()
    want = want.float().cpu()
    ok = torch.allclose(got, want, rtol=rtol, atol=atol)
    detail = "" if ok else "max abs error %.3g" % (got - want).abs().max().item()
    report(name, ok, detail)


def exact(name, got, want):
    bad = (got.cpu() != want.cpu()).sum().item()
    report(name, bad == 0, "" if bad == 0 else "%d / %d elements wrong" % (bad, want.numel()))


def test_device(dev, rounds, n):
    g = torch.Generator().manual_seed(1234 + dev.index if dev.index is not None else 1234)
    print("GPU %s: %s" % (dev, torch.cuda.get_device_name(dev) if dev.type == "cuda" else dev.type))

    # Copies: pageable and pinned (DMA), with a poisoned destination each round
    bad = 0
    for _ in range(rounds):
        host = torch.randint(-2**31, 2**31 - 1, (n,), dtype=torch.int32, generator=g)
        back = host.to(dev).cpu()
        bad += (back != host).sum().item()
    report("pageable H2D/D2H round trip", bad == 0, "" if bad == 0 else "%d wrong" % bad)

    bad = 0
    pin = dev.type == "cuda"
    src = torch.empty(n, dtype=torch.int32, pin_memory=pin)
    dst = torch.empty(n, dtype=torch.int32, pin_memory=pin)
    for _ in range(rounds):
        src.copy_(torch.randint(-2**31, 2**31 - 1, (n,), dtype=torch.int32, generator=g))
        dst.fill_(-1)
        d = src.to(dev, non_blocking=True)
        dst.copy_(d, non_blocking=True)
        if dev.type == "cuda":
            torch.cuda.synchronize(dev)
        bad += (dst != src).sum().item()
    report("pinned async round trip", bad == 0, "" if bad == 0 else "%d wrong" % bad)

    # Integer arithmetic must match exactly
    a = torch.randint(0, 1 << 20, (n,), dtype=torch.int64, generator=g)
    exact("int64 elementwise", (a.to(dev) * 3 + 7).cpu(), a * 3 + 7)

    # Float math vs the CPU
    x = torch.randn(512, 512, generator=g)
    y = torch.randn(512, 512, generator=g)
    close("fp32 matmul (cuBLAS)", x.to(dev) @ y.to(dev), x @ y, rtol=1e-3, atol=1e-2)
    close("fp16 matmul", (x.half().to(dev) @ y.half().to(dev)), x @ y, rtol=2e-2, atol=5e-1)
    close("sum reduction", x.to(dev).sum(dim=1), x.sum(dim=1), atol=1e-2)
    close("softmax", torch.softmax(x.to(dev), dim=-1), torch.softmax(x, dim=-1))
    close("layer_norm", F.layer_norm(x.to(dev), (512,)), F.layer_norm(x, (512,)))
    close("gelu", F.gelu(x.to(dev)), F.gelu(x))

    img = torch.randn(4, 3, 64, 64, generator=g)
    w = torch.randn(16, 3, 3, 3, generator=g)
    close("conv2d (cuDNN if built with it)", F.conv2d(img.to(dev), w.to(dev), padding=1),
          F.conv2d(img, w, padding=1), atol=1e-2)

    q, k, v = (torch.randn(2, 4, 64, 32, generator=g) for _ in range(3))
    close("scaled_dot_product_attention",
          F.scaled_dot_product_attention(q.to(dev), k.to(dev), v.to(dev)),
          F.scaled_dot_product_attention(q, k, v))

    # A tiny training step: forward, backward and an optimizer update
    torch.manual_seed(0)
    cpu_model = torch.nn.Sequential(torch.nn.Linear(64, 128), torch.nn.ReLU(), torch.nn.Linear(128, 10))
    dev_model = torch.nn.Sequential(torch.nn.Linear(64, 128), torch.nn.ReLU(), torch.nn.Linear(128, 10))
    dev_model.load_state_dict(cpu_model.state_dict())
    dev_model.to(dev)
    inp = torch.randn(32, 64, generator=g)
    tgt = torch.randint(0, 10, (32,), generator=g)
    for model, i, t in ((cpu_model, inp, tgt), (dev_model, inp.to(dev), tgt.to(dev))):
        opt = torch.optim.SGD(model.parameters(), lr=0.1)
        for _ in range(3):
            opt.zero_grad()
            F.cross_entropy(model(i), t).backward()
            opt.step()
    close("training step (3x SGD)", dev_model[0].weight, cpu_model[0].weight, atol=1e-3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=8)
    ap.add_argument("--mib", type=int, default=16, help="MiB per copy buffer")
    ap.add_argument("--expect-gpus", type=int, default=4)
    ap.add_argument("--device-type", default="cuda", help=argparse.SUPPRESS)  # "cpu" to test this script
    args = ap.parse_args()
    if args.rounds < 1 or args.mib < 1:
        ap.error("--rounds and --mib must be >= 1")
    n = args.mib * 1024 * 1024 // 4

    print("PyTorch %s, CUDA %s, cuDNN %s" % (torch.__version__, torch.version.cuda,
          torch.backends.cudnn.version() if torch.backends.cudnn.is_available() else "not built"))

    if args.device_type == "cpu":
        devices = [torch.device("cpu")]
    else:
        if not torch.cuda.is_available():
            print("CUDA not available. Check: nvidia-smi ; lsmod | grep nvidia_uvm ; sudo dmesg | grep NVRM")
            return 2
        arches = torch.cuda.get_arch_list()
        print("Compiled for: %s" % " ".join(arches))
        report("built for sm_50", "sm_50" in arches, "rebuild with TORCH_CUDA_ARCH_LIST=5.0")
        count = torch.cuda.device_count()
        report("GPUs visible", count >= args.expect_gpus, "%d of %d" % (count, args.expect_gpus))
        devices = [torch.device("cuda", i) for i in range(count)]
    print()

    for dev in devices:
        try:
            test_device(dev, args.rounds, n)
        except RuntimeError as e:
            report("no CUDA errors", False, str(e).splitlines()[0])
        print()

    # Copies between GPUs (through host memory unless peer access works)
    if len(devices) > 1:
        print("Cross-GPU copies:")
        data = torch.randn(n // 4)
        for i in range(1, len(devices)):
            exact("%s -> %s" % (devices[0], devices[i]), data.to(devices[0]).to(devices[i]).cpu(), data)
        print()

    print("RESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
