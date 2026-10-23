#include "NegiSensMeCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

typedef struct {
    uint16_t *data;
    size_t capacity, head, count;
} FeatureQueue;

struct NegiSensMeFeatures {
    NegiSensMeResampler *resampler;
    NegiSensMeFIR *low[6], *high[6], *tones[6][12];
    FeatureQueue queues[6][12];
    float energy[6][12], smoothed[6][12], alpha[6][12];
    size_t sample_counts[6];
    uint16_t previous_lowest[12];
    unsigned phase;
    int failed;
    NegiSensMeFeatureCallback callback;
    void *context;
};

static int queue_push(FeatureQueue *q, uint16_t value) {
    if (q->count == q->capacity) return 0;
    q->data[(q->head + q->count) % q->capacity] = value;
    q->count++;
    return 1;
}

static int queue_pop(FeatureQueue *q, uint16_t *value) {
    if (!q->count) return 0;
    *value = q->data[q->head];
    if (++q->head == q->capacity) q->head = 0;
    q->count--;
    return 1;
}

size_t negi_sensme_features_startup_frames(void) { return 292; }

NegiSensMeFeatures *negi_sensme_features_create(const int16_t *tone_coefficients,
                                               NegiSensMeFeatureCallback callback,
                                               void *context) {
    if (!tone_coefficients || !callback) return NULL;
    NegiSensMeFeatures *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->callback = callback;
    s->context = context;
    double target_rate = 7040.0 * pow(2.0, -1.0 + 5.0 / 24.0);
    s->resampler = negi_sensme_resampler_create(44100.0 / target_rate);
    if (!s->resampler) goto fail;

    // Audited half-band prototype: 255-point Hamming window centered at 127,
    // with one zero padding tap. Generate it instead of copying a DLL table.
    const double pi = 3.14159265358979323846264338327950288;
    int16_t low[256], high[256];
    for (int i=0; i<256; i++) {
        int distance = i - 127;
        double ideal = distance == 0 ? 0.5 : distance % 2 == 0 ? 0
            : sin(pi * 0.5 * distance) / (pi * distance);
        low[i] = (int16_t)(ideal * (0.54 + 0.46 * cos(pi * distance / 127.0)) * 32768.0);
        high[i] = i % 2 == 0 ? (int16_t)-low[i] : low[i];
    }

    size_t latencies[6], total = 0, factor = 1;
    for (int level=5; level>=0; level--) {
        factor *= 2;
        total += 128 * factor / 2;
        latencies[level] = 23 * factor + total;
    }
    size_t minimum_queue = (size_t)(target_rate * 8192.0 / 44100.0) / 32 + 2;
    for (int level=0; level<6; level++) {
        s->low[level] = negi_sensme_fir_create(low, 256);
        s->high[level] = negi_sensme_fir_create(high, 256);
        if (!s->low[level] || !s->high[level]) goto fail;
        size_t delay = (latencies[0] - latencies[level]) * 2 / 64;
        for (int tone=0; tone<12; tone++) {
            s->tones[level][tone] = negi_sensme_fir_create(tone_coefficients + tone*47, 47);
            FeatureQueue *q = &s->queues[level][tone];
            q->capacity = delay + minimum_queue;
            q->data = calloc(q->capacity, sizeof(uint16_t));
            q->count = delay;
            if (!s->tones[level][tone] || !q->data) goto fail;
            s->alpha[level][tone] = level < 2
                ? (float)pow(2.0, level - 2.0 + tone / 12.0) : 1.0f;
        }
    }
    return s;
fail:
    negi_sensme_features_destroy(s);
    return NULL;
}

void negi_sensme_features_destroy(NegiSensMeFeatures *s) {
    if (!s) return;
    negi_sensme_resampler_destroy(s->resampler);
    for (int level=0; level<6; level++) {
        negi_sensme_fir_destroy(s->low[level]);
        negi_sensme_fir_destroy(s->high[level]);
        for (int tone=0; tone<12; tone++) {
            negi_sensme_fir_destroy(s->tones[level][tone]);
            free(s->queues[level][tone].data);
        }
    }
    free(s);
}

static int emit_frames(NegiSensMeFeatures *s) {
    while (s->queues[0][0].count * 2 + s->phase) {
        uint16_t frame[72];
        for (int level=0; level<6; level++) {
            for (int tone=0; tone<12; tone++) {
                uint16_t value;
                if (level == 0 && s->phase) value = s->previous_lowest[tone];
                else {
                    if (!queue_pop(&s->queues[level][tone], &value)) return 0;
                    if (level == 0) s->previous_lowest[tone] = value;
                }
                frame[level*12 + tone] = value;
            }
        }
        s->phase = 1 - s->phase;
        if (!s->callback(s->context, frame)) return 0;
    }
    return 1;
}

static int process64(NegiSensMeFeatures *s, int16_t *samples) {
    size_t count = 64;
    for (int level=5; level>=0; level--) {
        count /= 2;
        size_t threshold = level > 1 ? (size_t)1 << (level-1) : 1;
        for (size_t i=0; i<count; i++) {
            int16_t high = negi_sensme_fir_push(s->high[level], samples[i*2]);
            int16_t low = negi_sensme_fir_push(s->low[level], samples[i*2]);
            negi_sensme_fir_feed(s->high[level], samples[i*2+1]);
            negi_sensme_fir_feed(s->low[level], samples[i*2+1]);
            samples[i] = low;
            for (int tone=0; tone<12; tone++) {
                int16_t value = negi_sensme_fir_push(s->tones[level][tone], high);
                double normalized = (double)value / 32768.0;
                s->energy[level][tone] = (float)(normalized * normalized + s->energy[level][tone]);
            }
            if (++s->sample_counts[level] < threshold) continue;
            for (int tone=0; tone<12; tone++) {
                double alpha = s->alpha[level][tone];
                double smooth = (1.0-alpha) * s->smoothed[level][tone]
                    + ((double)s->energy[level][tone] / threshold) * 262144.0 * alpha;
                s->smoothed[level][tone] = (float)smooth;
                // The x87 path stores a rounded float for the next sample but
                // truncates the unrounded current value for queue output.
                int32_t value = (int32_t)smooth;
                if (value > 65535) value = 65535;
                if (!queue_push(&s->queues[level][tone], (uint16_t)value)) return 0;
                s->energy[level][tone] = 0;
            }
            s->sample_counts[level] = 0;
        }
    }
    return emit_frames(s);
}

int negi_sensme_features_write(NegiSensMeFeatures *s, const int16_t *input, size_t count) {
    if (!s || s->failed || (count && !input) || count > 4096) return 0;
    float normalized[4096];
    for (size_t i=0; i<count; i++) normalized[i] = (float)input[i] / 32768.0f;
    if (!negi_sensme_resampler_write(s->resampler, normalized, count)) goto fail;
    while (negi_sensme_resampler_available(s->resampler) >= 64) {
        float resampled[64];
        int16_t samples[64];
        if (!negi_sensme_resampler_read(s->resampler, resampled, 64)) goto fail;
        for (size_t i=0; i<64; i++) {
            int32_t value = (int32_t)((double)resampled[i] * 32768.0);
            uint16_t word = (uint16_t)value;
            memcpy(&samples[i], &word, sizeof(word));
        }
        if (!process64(s, samples)) goto fail;
    }
    return 1;
fail:
    s->failed = 1;
    return 0;
}
