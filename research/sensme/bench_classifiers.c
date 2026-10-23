#include "NegiSensMeCore.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + value.tv_nsec * 1e-9;
}

int main(void) {
    enum { CASES = 32, REPEATS = 128, ROUNDS = 5 };
    NegiSensMeResultFeatures features[CASES] = {0};
    uint32_t seed = 0x39cf5050;
    for (unsigned i = 0; i < CASES; i++) {
        for (unsigned word = 0; word < 189; word++) {
            seed = 1664525u * seed + 1013904223u;
            features[i].words[word] = (seed >> 16) % 101;
        }
        double bpm = 30 + (seed % 270000) / 1000.0;
        memcpy(features[i].words + (0x2e0 - 0x10) / 4, &bpm, sizeof(bpm));
    }
    for (int round = 0; round < ROUNDS; round++) {
        uint64_t checksum = 0;
        double start = now();
        for (int repeat = 0; repeat < REPEATS; repeat++) {
            for (int i = 0; i < CASES; i++) {
                for (unsigned selector = 25; selector < 75; selector++) {
                    int32_t score;
                    if (!negi_sensme_classification_score(&features[i], selector, &score)) return 1;
                    checksum += (uint32_t)score;
                }
            }
        }
        printf("{\"round\":%d,\"seconds\":%.9f,\"tracks\":%d,\"scores\":%d,\"checksum\":%llu}\n",
               round, now() - start, CASES * REPEATS, CASES * REPEATS * 50,
               (unsigned long long)checksum);
    }
    return 0;
}
