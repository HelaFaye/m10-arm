// SPDX-License-Identifier: MIT
//
// m10_cuda_selftest.cu - correctness test for CUDA on a non-cache-coherent
// Arm host. Cache-coherency bugs usually show up as silently wrong data, not
// crashes, so every path that moves data between CPU and GPU is checked with
// a fresh pattern per round (stale data => mismatch).
//
// *** UNTESTED WORK IN PROGRESS. ***
//
// Build: nvcc -O2 -arch=sm_50 -o m10_cuda_selftest m10_cuda_selftest.cu
// Run:   ./m10_cuda_selftest [rounds] [MiB]

#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
    std::printf("    CUDA error %s at %s:%d: %s\n", cudaGetErrorName(e_), \
                __FILE__, __LINE__, cudaGetErrorString(e_)); return false; } } while (0)

__global__ void transform(const unsigned *in, unsigned *out, size_t n, unsigned k)
{
    for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n;
         i += (size_t)gridDim.x * blockDim.x)
        out[i] = (in[i] ^ k) * 2654435761u + (unsigned)i;
}

__global__ void fill(unsigned *out, size_t n, unsigned k)
{
    for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n;
         i += (size_t)gridDim.x * blockDim.x)
        out[i] = k + (unsigned)i * 7u;
}

__global__ void atomic_count(unsigned long long *ctr, int per_thread)
{
    for (int i = 0; i < per_thread; i++)
        atomicAdd(ctr, 1ull);
}

static inline unsigned expect_transform(unsigned in, size_t i, unsigned k)
{
    return (in ^ k) * 2654435761u + (unsigned)i;
}

static size_t count_bad_transform(const unsigned *in, const unsigned *out, size_t n, unsigned k)
{
    size_t bad = 0;
    for (size_t i = 0; i < n; i++)
        if (out[i] != expect_transform(in[i], i, k)) bad++;
    return bad;
}

static void pattern(unsigned *p, size_t n, unsigned seed)
{
    unsigned x = seed * 747796405u + 2891336453u;
    for (size_t i = 0; i < n; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = x; }
}

static bool report(const char *name, size_t bad, size_t n)
{
    std::printf("    %-34s %s", name, bad ? "FAIL" : "ok");
    if (bad) std::printf("  (%zu / %zu words wrong)", bad, n);
    std::printf("\n");
    return bad == 0;
}

// Count words that don't match fill()'s output.
static size_t count_bad_fill(const unsigned *p, size_t n, unsigned k)
{
    size_t bad = 0;
    for (size_t i = 0; i < n; i++)
        if (p[i] != k + (unsigned)i * 7u) bad++;
    return bad;
}

// 6. Registered user memory (cudaHostRegister). The patched driver refuses it
//    on non-coherent hosts (stale-cache corruption otherwise), so a clean
//    error is a pass; if it is allowed, the data must be right.
static bool test_host_register(int dev, int rounds, size_t n, unsigned *d_in, unsigned *d_out)
{
    const size_t bytes = n * sizeof(unsigned);
    unsigned *buf = (unsigned *)std::aligned_alloc(4096, (bytes + 4095) & ~(size_t)4095);
    if (!buf) { std::printf("    cudaHostRegister: out of host memory\n"); return false; }
    std::vector<unsigned> ref(n);   // buf is reused for the result

    cudaError_t e = cudaHostRegister(buf, bytes, cudaHostRegisterDefault);
    if (e != cudaSuccess) {
        cudaGetLastError();   // clear the (non-sticky) error
        std::printf("    %-34s ok  (refused: %s - expected on non-coherent hosts)\n",
                    "cudaHostRegister", cudaGetErrorName(e));
        std::free(buf);
        return true;
    }

    size_t bad = 0;
    for (int r = 0; r < rounds; r++) {
        pattern(buf, n, 5000u * dev + r);
        std::memcpy(ref.data(), buf, bytes);
        unsigned k = 0x165667b1u * (r + 1);
        CK(cudaMemcpy(d_in, buf, bytes, cudaMemcpyHostToDevice));
        transform<<<256, 256>>>(d_in, d_out, n, k);
        CK(cudaGetLastError());
        std::memset(buf, 0xEF, bytes);   // poison: stale data must not survive
        CK(cudaMemcpy(buf, d_out, bytes, cudaMemcpyDeviceToHost));
        bad += count_bad_transform(ref.data(), buf, n, k);
    }
    bool ok = report("cudaHostRegister (allowed) memcpy", bad, n * rounds);
    CK(cudaHostUnregister(buf));
    std::free(buf);
    return ok;
}

// 7. Managed memory (cudaMallocManaged): CPU writes, GPU transforms, CPU
//    reads, with fresh data each round. On Maxwell, pages migrate at kernel
//    launch/sync - this is the nvidia-uvm path, not the RM one.
static bool test_managed(int dev, int rounds, size_t n)
{
    const size_t bytes = n * sizeof(unsigned);
    unsigned *in, *out;
    CK(cudaMallocManaged(&in, bytes));
    CK(cudaMallocManaged(&out, bytes));
    size_t bad = 0, bad_fill = 0;
    for (int r = 0; r < rounds; r++) {
        pattern(in, n, 6000u * dev + r);
        std::memset(out, 0x5A, bytes);
        unsigned k = 0xd3a2646cu * (r + 1);
        transform<<<256, 256>>>(in, out, n, k);
        CK(cudaGetLastError());
        CK(cudaDeviceSynchronize());
        bad += count_bad_transform(in, out, n, k);

        fill<<<256, 256>>>(out, n, k);   // GPU-only write, then CPU read
        CK(cudaGetLastError());
        CK(cudaDeviceSynchronize());
        bad_fill += count_bad_fill(out, n, k);
    }
    bool ok = report("managed CPU->GPU->CPU", bad, n * rounds);
    ok &= report("managed GPU write -> CPU read", bad_fill, n * rounds);
    CK(cudaFree(in)); CK(cudaFree(out));
    return ok;
}

static bool test_device(int dev, int rounds, size_t n)
{
    cudaDeviceProp p;
    CK(cudaSetDevice(dev));
    CK(cudaGetDeviceProperties(&p, dev));
    std::printf("GPU %d: %s  sm_%d%d  %.1f GiB  PCI %04x:%02x:%02x\n", dev, p.name,
                p.major, p.minor, p.totalGlobalMem / 1073741824.0,
                p.pciDomainID, p.pciBusID, p.pciDeviceID);

    const size_t bytes = n * sizeof(unsigned);
    const int blocks = 256, threads = 256;
    bool ok = true;

    unsigned *d_in, *d_out;
    CK(cudaMalloc(&d_in, bytes));
    CK(cudaMalloc(&d_out, bytes));

    // 1. Pageable memcpy round trip through a kernel.
    std::vector<unsigned> h_in(n), h_out(n);
    size_t bad = 0;
    for (int r = 0; r < rounds; r++) {
        pattern(h_in.data(), n, 1000u * dev + r);
        unsigned k = 0x9e3779b9u * (r + 1);
        CK(cudaMemcpy(d_in, h_in.data(), bytes, cudaMemcpyHostToDevice));
        transform<<<blocks, threads>>>(d_in, d_out, n, k);
        CK(cudaGetLastError());
        CK(cudaMemcpy(h_out.data(), d_out, bytes, cudaMemcpyDeviceToHost));
        bad += count_bad_transform(h_in.data(), h_out.data(), n, k);
    }
    ok &= report("pageable memcpy H2D/kernel/D2H", bad, n * rounds);

    // 2. Pinned (page-locked) memory, async copies - the DMA path.
    unsigned *p_in, *p_out;
    CK(cudaHostAlloc(&p_in, bytes, cudaHostAllocDefault));
    CK(cudaHostAlloc(&p_out, bytes, cudaHostAllocDefault));
    cudaStream_t s;
    CK(cudaStreamCreate(&s));
    bad = 0;
    for (int r = 0; r < rounds; r++) {
        pattern(p_in, n, 2000u * dev + r);
        std::memset(p_out, 0xAB, bytes);   // poison: stale data must not survive
        unsigned k = 0x85ebca6bu * (r + 1);
        CK(cudaMemcpyAsync(d_in, p_in, bytes, cudaMemcpyHostToDevice, s));
        transform<<<blocks, threads, 0, s>>>(d_in, d_out, n, k);
        CK(cudaMemcpyAsync(p_out, d_out, bytes, cudaMemcpyDeviceToHost, s));
        CK(cudaStreamSynchronize(s));
        bad += count_bad_transform(p_in, p_out, n, k);
    }
    ok &= report("pinned async memcpy", bad, n * rounds);

    // 3. Zero-copy: GPU reads/writes mapped host memory directly.
    unsigned *m_buf, *m_dev;
    CK(cudaHostAlloc(&m_buf, bytes, cudaHostAllocMapped));
    CK(cudaHostGetDevicePointer(&m_dev, m_buf, 0));
    bad = 0;
    for (int r = 0; r < rounds; r++) {
        std::memset(m_buf, 0xCD, bytes);   // CPU writes old data first
        unsigned k = 0xc2b2ae35u * (r + 1);
        fill<<<blocks, threads>>>(m_dev, n, k);
        CK(cudaGetLastError());
        CK(cudaDeviceSynchronize());
        bad += count_bad_fill(m_buf, n, k);
    }
    ok &= report("zero-copy GPU->host writes", bad, n * rounds);

    // 4. Zero-copy CPU->GPU: CPU writes, GPU reads (kernel output in VRAM).
    bad = 0;
    for (int r = 0; r < rounds; r++) {
        pattern(m_buf, n, 3000u * dev + r);
        unsigned k = 0x27d4eb2fu * (r + 1);
        transform<<<blocks, threads>>>(m_dev, d_out, n, k);
        CK(cudaGetLastError());
        CK(cudaMemcpy(h_out.data(), d_out, bytes, cudaMemcpyDeviceToHost));
        bad += count_bad_transform(m_buf, h_out.data(), n, k);
    }
    ok &= report("zero-copy host->GPU reads", bad, n * rounds);

    // 5. Atomics: device memory, then mapped host memory (the risky case on
    //    uncached Arm mappings).
    const int at_blocks = 64, at_threads = 128, per = 64;
    const unsigned long long want = (unsigned long long)at_blocks * at_threads * per;
    unsigned long long *d_ctr, h_ctr = 0;
    CK(cudaMalloc(&d_ctr, sizeof *d_ctr));
    CK(cudaMemset(d_ctr, 0, sizeof *d_ctr));
    atomic_count<<<at_blocks, at_threads>>>(d_ctr, per);
    CK(cudaGetLastError());
    CK(cudaMemcpy(&h_ctr, d_ctr, sizeof h_ctr, cudaMemcpyDeviceToHost));
    ok &= report("atomics in device memory", h_ctr != want, 1);

    unsigned long long *m_ctr, *m_ctr_dev;
    CK(cudaHostAlloc(&m_ctr, sizeof *m_ctr, cudaHostAllocMapped));
    CK(cudaHostGetDevicePointer(&m_ctr_dev, m_ctr, 0));
    // Informational only: CUDA doesn't guarantee atomics on mapped host
    // memory over PCIe for Maxwell, so a mismatch here may happen on x86
    // too. A hang or bus error here, though, points at the Arm host.
    *m_ctr = 0;
    atomic_count<<<at_blocks, at_threads>>>(m_ctr_dev, per);
    CK(cudaGetLastError());
    CK(cudaDeviceSynchronize());
    std::printf("    %-34s %s  (informational, not counted)\n",
                "atomics in mapped host memory", *m_ctr == want ? "ok" : "MISMATCH");

    ok &= test_host_register(dev, rounds, n, d_in, d_out);
    ok &= test_managed(dev, rounds, n);

    CK(cudaFreeHost(m_ctr)); CK(cudaFree(d_ctr));
    CK(cudaFreeHost(m_buf));
    CK(cudaStreamDestroy(s));
    CK(cudaFreeHost(p_in)); CK(cudaFreeHost(p_out));
    CK(cudaFree(d_in)); CK(cudaFree(d_out));
    return ok;
}

static bool test_peer(int a, int b, size_t n)
{
    int can = 0;
    CK(cudaDeviceCanAccessPeer(&can, a, b));
    std::printf("Peer %d->%d: %s\n", a, b, can ? "supported" : "not supported (copies go via host)");
    const size_t bytes = n * sizeof(unsigned);
    std::vector<unsigned> h(n), back(n);
    pattern(h.data(), n, 4242u + a * 10 + b);
    unsigned *da, *db;
    CK(cudaSetDevice(a)); CK(cudaMalloc(&da, bytes));
    CK(cudaSetDevice(b)); CK(cudaMalloc(&db, bytes));
    CK(cudaMemcpy(da, h.data(), bytes, cudaMemcpyHostToDevice));
    CK(cudaMemcpyPeer(db, b, da, a, bytes));
    CK(cudaMemcpy(back.data(), db, bytes, cudaMemcpyDeviceToHost));
    size_t bad = 0;
    for (size_t i = 0; i < n; i++) if (back[i] != h[i]) bad++;
    bool ok = report("cudaMemcpyPeer", bad, n);
    CK(cudaFree(db)); CK(cudaSetDevice(a)); CK(cudaFree(da));
    return ok;
}

int main(int argc, char **argv)
{
    int rounds = argc > 1 ? std::atoi(argv[1]) : 8;
    int mib_arg = argc > 2 ? std::atoi(argv[2]) : 64;
    if (rounds < 1 || mib_arg < 1) {
        std::printf("usage: %s [rounds >= 1] [MiB >= 1]\n", argv[0]);
        return 2;
    }
    size_t mib = (size_t)mib_arg;
    size_t n = mib * 1024 * 1024 / sizeof(unsigned);

    int drv = 0, rt = 0, count = 0;
    cudaDriverGetVersion(&drv);
    cudaRuntimeGetVersion(&rt);
    cudaError_t e = cudaGetDeviceCount(&count);
    std::printf("M10 CUDA self-test (UNTESTED WIP)  driver API %d, runtime %d\n", drv, rt);
    if (e != cudaSuccess || count == 0) {
        std::printf("No CUDA devices: %s\n", cudaGetErrorString(e));
        std::printf("Check: lsmod | grep nvidia_uvm ; ls -l /dev/nvidia* ; sudo dmesg | grep NVRM\n");
        return 2;
    }
    std::printf("%d device(s), %d round(s), %zu MiB per buffer\n\n", count, rounds, mib);

    bool ok = true;
    for (int d = 0; d < count; d++) {
        ok &= test_device(d, rounds, n);
        std::printf("\n");
    }
    for (int d = 1; d < count; d++)
        ok &= test_peer(0, d, n);

    std::printf("\nRESULT: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
