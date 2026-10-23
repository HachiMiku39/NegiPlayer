#include "NegiSensMeCore.h"
#include <stdlib.h>
#include <string.h>
#if defined(__aarch64__) || defined(_M_ARM64)
#include <arm_neon.h>
#endif

/* Explicit floor division avoids implementation-defined negative shifts. */
static int32_t floor_shift(int32_t value, unsigned bits) {
    int64_t wide = value;
    int64_t denominator = (int64_t)1 << bits;
    return (int32_t)(wide >= 0 ? wide / denominator
                              : -((-wide + denominator - 1) / denominator));
}

static int16_t low_signed_word(int32_t value) {
    uint16_t bits = (uint16_t)((uint32_t)value & UINT16_MAX);
    int16_t result;
    memcpy(&result, &bits, sizeof(result));
    return result;
}

size_t negi_sensme_prepare_pcm(NegiSensMePCMState *state,
                             const int16_t *input, size_t frames,
                             unsigned channels, int16_t *output) {
    if (!state || channels < 1 || channels > 2 || frames > SIZE_MAX / channels)
        return SIZE_MAX;
    if (!frames) return 0;
    if (!input || !output) return SIZE_MAX;
    size_t used = 0;
    for (size_t frame = 0; frame < frames; ++frame) {
        int16_t left = input[frame * channels];
        int16_t right = channels == 2 ? input[frame * channels + 1] : left;
        if (!state->has_signal) {
            if (left == 0 && right == 0) {
                if (state->leading_zero_frames != UINT64_MAX)
                    state->leading_zero_frames++;
                continue;
            }
            state->has_signal = 1;
        }
        output[used++] = channels == 1 ? left
            : (int16_t)floor_shift((int32_t)left + (int32_t)right, 1);
    }
    return used;
}

struct NegiSensMeFIR {
    size_t taps;
    size_t padded_taps;
    size_t position;
    int16_t *coefficients;
    int16_t *history;
};

NegiSensMeFIR *negi_sensme_fir_create(const int16_t *coefficients, size_t taps) {
    if (!coefficients || taps == 0 || taps > 65536) return NULL;
    NegiSensMeFIR *filter = calloc(1, sizeof(*filter));
    if (!filter) return NULL;
    filter->taps = taps;
    filter->padded_taps = (taps + 15) & ~(size_t)15;
    filter->coefficients = calloc(filter->padded_taps, sizeof(int16_t));
    filter->history = calloc(taps + filter->padded_taps, sizeof(int16_t));
    if (!filter->coefficients || !filter->history) {
        negi_sensme_fir_destroy(filter);
        return NULL;
    }
    memcpy(filter->coefficients, coefficients, taps * sizeof(int16_t));
    return filter;
}

void negi_sensme_fir_reset(NegiSensMeFIR *filter) {
    if (!filter) return;
    memset(filter->history, 0,
           (filter->taps + filter->padded_taps) * sizeof(int16_t));
    filter->position = 0;
}

void negi_sensme_fir_destroy(NegiSensMeFIR *filter) {
    if (!filter) return;
    free(filter->coefficients);
    free(filter->history);
    free(filter);
}

static const int16_t *feed(NegiSensMeFIR *filter, int16_t sample) {
    size_t index = filter->taps - 1 - filter->position;
    filter->history[index] = sample;
    filter->history[index + filter->taps] = sample;
    if (++filter->position == filter->taps) filter->position = 0;
    return filter->history + index;
}

void negi_sensme_fir_feed(NegiSensMeFIR *filter, int16_t sample) {
    if (filter) feed(filter, sample);
}

int16_t negi_sensme_fir_push(NegiSensMeFIR *filter, int16_t sample) {
    if (!filter) return 0;
    const int16_t *history = feed(filter, sample);
    uint32_t sum = 0;
#if (defined(__aarch64__) || defined(_M_ARM64)) && !defined(NEGI_SENSME_SCALAR)
    /* Unsigned vector additions preserve MMX modulo-2^32 arithmetic, including
       pmaddwd's signed overflow case. No saturating or floating point math. */
    uint32x4_t totals = vdupq_n_u32(0);
    for (size_t i = 0; i < filter->padded_taps; i += 8) {
        int16x8_t a = vld1q_s16(history + i);
        int16x8_t b = vld1q_s16(filter->coefficients + i);
        totals = vaddq_u32(totals, vreinterpretq_u32_s32(vmull_s16(vget_low_s16(a), vget_low_s16(b))));
        totals = vaddq_u32(totals, vreinterpretq_u32_s32(vmull_s16(vget_high_s16(a), vget_high_s16(b))));
    }
    sum = vaddvq_u32(totals);
#else
    for (size_t i = 0; i < filter->taps; ++i)
        sum += (uint32_t)((int32_t)history[i] * (int32_t)filter->coefficients[i]);
#endif
    int32_t signed_sum;
    memcpy(&signed_sum, &sum, sizeof(signed_sum));
    return low_signed_word(floor_shift(signed_sum, 15));
}
