#include <cstdio>
#include <cuda_runtime.h>
int main() {
    int n = 0; cudaGetDeviceCount(&n);
    printf("devices=%d\n", n);
    for (int d = 0; d < n; d++) {
        cudaSetDevice(d); cudaFree(0);
        for (int p = 0; p < n; p++) {
            if (p == d) { printf("  %d->%d self\n", d, p); continue; }
            int can = 0; cudaError_t e = cudaDeviceCanAccessPeer(&can, d, p);
            printf("  %d->%d canAccess=%d (err=%s)\n", d, p, can, cudaGetErrorName(e));
        }
        cudaDeviceReset();
    }
    return 0;
}
