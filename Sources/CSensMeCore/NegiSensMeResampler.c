#include "NegiSensMeCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

struct NegiSensMeResampler {
    size_t decimation;
    size_t capacity;
    size_t write_position;
    double read_position;
    double step;
    size_t pending_count;
    float *ring;
    float *pending;
};

NegiSensMeResampler *negi_sensme_resampler_create(double ratio) {
    if (!isfinite(ratio) || ratio < 1.0 / 65536 || ratio > 4096) return NULL;
    NegiSensMeResampler *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->decimation = 1;
    state->step = ratio;
    while (state->step >= 2) {
        state->step *= 0.5;
        state->decimation *= 2;
    }
    state->capacity = 16384 / state->decimation;
    state->ring = calloc(state->capacity, sizeof(float));
    state->pending = calloc(state->decimation, sizeof(float));
    if (!state->ring || !state->pending) {
        negi_sensme_resampler_destroy(state);
        return NULL;
    }
    return state;
}

void negi_sensme_resampler_destroy(NegiSensMeResampler *state) {
    if (!state) return;
    free(state->ring);
    free(state->pending);
    free(state);
}

void negi_sensme_resampler_reset(NegiSensMeResampler *state) {
    if (!state) return;
    state->write_position = state->pending_count = 0;
    state->read_position = 0;
    memset(state->ring, 0, state->capacity * sizeof(float));
    memset(state->pending, 0, state->decimation * sizeof(float));
}

int negi_sensme_resampler_write(NegiSensMeResampler *state, const float *input, size_t count) {
    if (!state || (count && !input) || count > SIZE_MAX - state->pending_count) return 0;
    size_t read = (size_t)state->read_position;
    size_t free_slots = read > state->write_position
        ? read - state->write_position
        : state->capacity - state->write_position + read;
    // Keep one ring slot free so full and empty cannot have identical cursors.
    // The audited analysis caller drains every <=4096 source samples and never
    // reaches this boundary; the public native API rejects it explicitly.
    if ((count + state->pending_count) / state->decimation >= free_slots) return 0;
    for (size_t i=0; i<count; i++) {
        state->pending[state->pending_count++] = input[i];
        if (state->pending_count != state->decimation) continue;
        /* PCM comes from int16/32768. At the audited analysis rates its block
           sum is exact in double; do not introduce per-add float rounding. */
        double sum = 0;
        for (size_t j=0; j<state->decimation; j++) sum += state->pending[j];
        state->ring[state->write_position] = (float)(sum / (double)state->decimation);
        state->pending_count = 0;
        if (++state->write_position == state->capacity) state->write_position = 0;
    }
    return 1;
}

size_t negi_sensme_resampler_available(const NegiSensMeResampler *state) {
    if (!state) return 0;
    size_t read = (size_t)state->read_position;
    size_t distance = state->write_position >= read
        ? state->write_position - read
        : state->capacity - read + state->write_position;
    // Preserve the reference integer-cursor estimate. At a write boundary it
    // can permit interpolation into the next (not yet written) ring slot.
    // Full-analysis compatibility therefore includes input dispatch boundaries.
    return (size_t)((double)distance / state->step);
}

int negi_sensme_resampler_read(NegiSensMeResampler *state, float *output, size_t count) {
    if (!state || (count && !output) || count > SIZE_MAX / sizeof(float)) return 0;
    if (!count) return 1;
    if (negi_sensme_resampler_available(state) < count) {
        memset(output, 0, count * sizeof(float));
        return 0;
    }
    for (size_t i=0; i<count; i++) {
        size_t index = (size_t)state->read_position;
        size_t next = index + 1 < state->capacity ? index + 1 : 0;
        double fraction = state->read_position - (double)index;
        // The original stores the first weighted term as float before adding
        // the second term. Preserve this rounding and prohibit fused multiply-add.
        float first = (float)((1.0 - fraction) * (double)state->ring[index]);
        output[i] = (float)((double)first + fraction * (double)state->ring[next]);
        state->read_position += state->step;
        if (state->read_position >= (double)state->capacity)
            state->read_position -= (double)state->capacity;
    }
    return 1;
}
