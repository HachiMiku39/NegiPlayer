#include "NegiSensMeCore.h"
#include <inttypes.h>
#include <stdio.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + (double)t.tv_nsec / 1e9;
}

int main(void) {
    for (size_t n = 47; n <= 256; n += 209) {
        int16_t coefficients[256];
        uint32_t seed = UINT32_C(0x39c0ffee);
        for (size_t i=0; i<n; i++) {
            seed = UINT32_C(1664525) * seed + UINT32_C(1013904223);
            coefficients[i] = (int16_t)(seed >> 16);
        }
        NegiSensMeFIR *f = negi_sensme_fir_create(coefficients, n);
        if (!f) return 1;
        const unsigned count = 2000000;
        double start = now();
        uint64_t checksum = 0;
        for (unsigned i=0; i<count; i++) {
            seed = UINT32_C(1664525) * seed + UINT32_C(1013904223);
            checksum += (uint16_t)negi_sensme_fir_push(f, (int16_t)(seed >> 16));
        }
        printf("{\"taps\":%zu,\"samples\":%u,\"seconds\":%.6f,\"checksum\":%" PRIu64 "}\n", n, count, now()-start, checksum);
        negi_sensme_fir_destroy(f);
    }
    return 0;
}
