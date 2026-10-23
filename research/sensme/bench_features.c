#include "NegiSensMeCore.h"
#include <stdint.h>
#include <stdio.h>
#include <time.h>

typedef struct { size_t frames; uint64_t sum; } Result;
static int collect(void *context, const uint16_t *frame) {
    Result *result = context;
    result->frames++;
    for (int i=0; i<72; i++) result->sum += frame[i];
    return 1;
}
static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + (double)t.tv_nsec / 1e9;
}
int main(void) {
    uint32_t seed = 0x39fa1234;
    int16_t coefficients[12*47], input[4096];
    for (int i=0; i<12*47; i++) {
        seed = 1664525 * seed + 1013904223;
        coefficients[i] = (int16_t)(seed >> 16) / 16 + (i%47 == 23 ? 12000 : 0);
    }
    for (int i=0; i<4096; i++) {
        seed = 1664525 * seed + 1013904223;
        input[i] = (int16_t)(seed >> 16);
    }
    Result result = {0};
    NegiSensMeFeatures *state = negi_sensme_features_create(coefficients, collect, &result);
    if (!state) return 1;
    size_t samples = 44100 * 100;
    double start = now();
    for (size_t at=0; at<samples;) {
        size_t count = samples - at < 4096 ? samples - at : 4096;
        if (!negi_sensme_features_write(state, input, count)) return 2;
        at += count;
    }
    double elapsed = now() - start;
    negi_sensme_features_destroy(state);
    printf("{\"audioSeconds\":100,\"rawFrames\":%zu,\"seconds\":%.6f,\"checksum\":%llu}\n",
           result.frames, elapsed, (unsigned long long)result.sum);
    return 0;
}
