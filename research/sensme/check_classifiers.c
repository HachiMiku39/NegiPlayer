#include "NegiSensMeCore.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Local binary vectors: uint32 count, then 189 prepared words and 50 expected
   score words per case. Real-track vectors remain outside the repository. */
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file) return 2;
    uint32_t count;
    if (fread(&count, sizeof(count), 1, file) != 1 || count > 10000) return 2;
    for (uint32_t index = 0; index < count; index++) {
        NegiSensMeResultFeatures features, before;
        uint32_t expected[50];
        if (fread(&features, sizeof(features), 1, file) != 1 ||
            fread(expected, sizeof(expected), 1, file) != 1) return 2;
        before = features;
        for (unsigned selector = 25; selector < 75; selector++) {
            int32_t output = -123456;
            if (!negi_sensme_classification_score(&features, selector, &output) ||
                (uint32_t)output != expected[selector - 25]) {
                fprintf(stderr, "Mismatch at case %u selector %u\n", index, selector);
                return 1;
            }
        }
        if (memcmp(&before, &features, sizeof(features))) return 1;
    }
    if (fgetc(file) != EOF) return 2;
    fclose(file);
    NegiSensMeResultFeatures invalid = {0};
    int32_t output = -123456;
    if (negi_sensme_classification_score(NULL, 25, &output) || output != -123456 ||
        negi_sensme_classification_score(&invalid, 75, &output) || output != -123456 ||
        negi_sensme_classification_score(&invalid, 25, NULL)) return 1;
    double bpm = NAN;
    memcpy(invalid.words + (0x2e0 - 0x10) / 4, &bpm, sizeof(bpm));
    if (negi_sensme_classification_score(&invalid, 25, &output) || output != -123456) return 1;
    printf("%u cases, %u exact scores, input retention and invalid-input guards passed\n", count, count * 50);
    return 0;
}
