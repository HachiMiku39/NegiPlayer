#ifndef NEGI_SENSME_CORE_H
#define NEGI_SENSME_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Native default 1.6.1 core, composition interface and audited building blocks. */
typedef struct {
    uint64_t leading_zero_frames;
    int has_signal;
} NegiSensMePCMState;

/* Trim exact leading zero frames across calls, then downmix signed PCM using
   floor((left + right) / 2). Anti-phase stereo starts the signal even if its
   mono sum is zero. Input and output may alias. SIZE_MAX indicates bad arguments.
   A zero-frame call leaves state unchanged and accepts null buffers. */
size_t negi_sensme_prepare_pcm(NegiSensMePCMState *state,
                             const int16_t *input, size_t frames,
                             unsigned channels, int16_t *output);

typedef struct NegiSensMeFIR NegiSensMeFIR;

/* Streaming Q15 FIR with signed 16-bit taps, wrapping 32-bit accumulation and
   arithmetic right shift, matching the audited x86 integer path. Coefficients
   are caller-owned analysis parameters, copied by create. No embedded Sony
   model or coefficients. NULL indicates invalid size or allocation failure. */
NegiSensMeFIR *negi_sensme_fir_create(const int16_t *coefficients, size_t taps);
void negi_sensme_fir_reset(NegiSensMeFIR *filter);
void negi_sensme_fir_destroy(NegiSensMeFIR *filter);
int16_t negi_sensme_fir_push(NegiSensMeFIR *filter, int16_t sample);
/* Feed a sample into history without calculating a result (decimator phase). */
void negi_sensme_fir_feed(NegiSensMeFIR *filter, int16_t sample);

typedef struct NegiSensMeResampler NegiSensMeResampler;
/* Analysis-path resampler: power-of-two block means followed by linear
   interpolation. This is not the playback SRC. Ratio = input/output rate;
   accepted range 1/65536 ... 4096. Input is normalized float PCM. */
NegiSensMeResampler *negi_sensme_resampler_create(double ratio);
void negi_sensme_resampler_destroy(NegiSensMeResampler *state);
void negi_sensme_resampler_reset(NegiSensMeResampler *state);
/* Write is all-or-nothing when the internal ring lacks space (one slot is
   reserved to distinguish full from empty); zero-length
   operations accept null data. Return 1 on success, 0 on invalid/full state. */
int negi_sensme_resampler_write(NegiSensMeResampler *state, const float *input, size_t count);
size_t negi_sensme_resampler_available(const NegiSensMeResampler *state);
/* Insufficient input: zero the requested output, leave state unchanged, return
   0. Success: fill exactly count outputs and return 1. */
int negi_sensme_resampler_read(NegiSensMeResampler *state, float *output, size_t count);

typedef struct NegiSensMeFeatures NegiSensMeFeatures;
/* One raw energy frame, octave-major (6*12 uint16 values). Callback data is
   borrowed until return; return 0 to stop processing, 1 to continue. This is
   not a mood/channel result or complete SMFMF analysis. */
typedef int (*NegiSensMeFeatureCallback)(void *context, const uint16_t *frame);
/* Create the audited default bank using its embedded recovered numeric tone
   parameters. No runtime DLL or external parameter file is required. callback
   is required; allocation failure/invalid callback returns null. */
NegiSensMeFeatures *negi_sensme_features_create_default(NegiSensMeFeatureCallback callback, void *context);
/* Custom-bank constructor. Input is mono signed 16-bit at 44100 Hz. The 12*47
   tone coefficients are supplied by the caller; remaining filter parameters are generated
   mathematically. Processing uses <=4096-frame input blocks. To reproduce
   legacy full-analysis bytes, retain its PCM dispatch boundaries: the original
   resampler can interpolate into its next ring slot before that slot is
   submitted. Arbitrary repartitioning is not guaranteed byte-invariant. */
NegiSensMeFeatures *negi_sensme_features_create(const int16_t *tone_coefficients,
                                               NegiSensMeFeatureCallback callback,
                                               void *context);
void negi_sensme_features_destroy(NegiSensMeFeatures *state);
int negi_sensme_features_write(NegiSensMeFeatures *state, const int16_t *input, size_t count);
size_t negi_sensme_features_startup_frames(void);

typedef struct NegiSensMeSpectralStats NegiSensMeSpectralStats;
/* Mono statistics of raw 72-band energy, after startup removal. One instance
   retains history across 128-frame blocks. weighted=1 selects the audited
   weighted profile; 0 selects its generic companion. No mood/BPM output yet. */
NegiSensMeSpectralStats *negi_sensme_spectral_create(int weighted);
void negi_sensme_spectral_destroy(NegiSensMeSpectralStats *state);
/* Final volume feature from all submitted blocks: rounded mean amplitude,
   then 6*ln(mean)/ln(2) for a positive mean. This is an analysis feature,
   not ReplayGain or playback gain. Reading retains the accumulator.
   Requires 1..INT32_MAX/72 processed frames. Returns 1 on success, 0 for
   invalid/empty input, leaving output unchanged. */
int negi_sensme_spectral_volume(const NegiSensMeSpectralStats *state, float *output);
/* Exactly 128*72 input words. means/deviations each have 16 floats. Optional
   series has 16*128 floats in stream-major order. Audited mono profiles only;
   this layer does not perform track classification or tempo estimation. */
int negi_sensme_spectral_block(NegiSensMeSpectralStats *state, const uint16_t *input,
                                float *means, float *deviations, float *series);
/* Aggregate block-major [16 means,16 deviations] to the audited 64-value
   layout: mean(means), deviation(means), mean(deviations), deviation(deviations).
   Zero blocks yields a zero summary, as in the original empty accumulator. */
int negi_sensme_spectral_summary(const float *blocks, size_t count, float *summary);

typedef struct NegiSensMeDynamics NegiSensMeDynamics;
/* Audited mono tone/onset accumulator. Accepts complete post-startup 128*72
   energy blocks, at most 297 blocks (the original analysis window).
   Output tones: 3 groups * 64 pair-frames * 12 uint16 words, group-major.
   Output onsets: 3 bands * 128 floats, band-major; initial 52 frames are zero
   because the reference onset sequence starts only after its history window.
   These intermediate features do not constitute BPM or mood analysis. */
NegiSensMeDynamics *negi_sensme_dynamics_create(void);
void negi_sensme_dynamics_destroy(NegiSensMeDynamics *state);
int negi_sensme_dynamics_block(NegiSensMeDynamics *state, const uint16_t *input,
                                uint16_t *tones, float *onsets);

typedef struct NegiSensMeFFT NegiSensMeFFT;
/* Analysis FFT, power-of-two lengths 2..4096, not used in the playback path.
   Input/output each contain count floats; output is normalized by count,
   packed as [DC, Nyquist, real(1), imag(1), ...]. A plan owns mutable scratch
   and must not be shared by concurrent analyses. Input/output may alias. */
NegiSensMeFFT *negi_sensme_fft_create(size_t count);
void negi_sensme_fft_destroy(NegiSensMeFFT *state);
int negi_sensme_fft_real(NegiSensMeFFT *state, const float *input, float *output);
/* Default 4096-point tempo candidate search. Input is the packed FFT above;
   optional magnitude output holds 2049 floats. Returns a spectral candidate
   index (zero for no candidate), or -1 on null input. This is not final BPM. */
int negi_sensme_tempo_candidate(const float *packed, float *magnitudes);
/* Full-analysis traversal retains the previous candidate when no coarse
   maximum is found, then still searches its local neighborhood. previous
   must be 0..2047; zero starts a new analysis. Invalid input returns -1. */
int negi_sensme_tempo_candidate_seeded(const float *packed, float *magnitudes, int previous);

/* Accumulate one 2049-bin band-2 magnitude spectrum into a caller-zeroed
   256-float logarithmic profile. Submit segments in original order. Returns
   zero for invalid/unrepresentable data without changing the profile. */
int negi_sensme_tempo_spectrum_accumulate(const float *magnitudes, float *profile);

/* Normalized weighted spread of profile bins 10..255. Output is unchanged on
   invalid input. This statistic is independent of the voted tempo candidate. */
int negi_sensme_tempo_spectrum_spread(const float *profile, float *spread);
/* Default candidate voting, including octave agreement and first-wins ties.
   Returns the selected candidate (zero if none), -1 for invalid input.
   Optional votes has count elements. count must be in 1..30. */
int negi_sensme_tempo_vote(const int32_t *candidates, size_t count, int32_t *votes);

typedef struct {
    int32_t selected_candidate, adjusted_candidate;
    double raw_period, initial_period, initial_phase, refined_period;
    double first_phase, final_period, final_phase;
    float predicted_log_bpm, bpm, period_frames, phase_frames;
} NegiSensMeTempoEstimate;
/* Default mono tempo refinement, before tonal features and downbeat alignment.
   onsets is band-major 3*frames floats, with the 52 history frames removed and
   zero padding at the end (matching the original record arrays). frames must
   be a multiple of 128 in 0..38016. Zero frames reproduces the original empty
   diagnostic, whose computed BPM must not be published as a valid estimate.
   Candidates are segment-major triples;
   segment count is max(1,floor(frames/4096)). stats is block-major weighted
   profile [16 means,16 deviations], one block per 128 frames. Optional weighted
   has frames floats. Does not create a beat grid or SMFMF. */
int negi_sensme_tempo_refine(const int32_t *candidates, size_t candidate_count,
                            const float *onsets, size_t frames, const float *stats,
                            NegiSensMeTempoEstimate *estimate, float *weighted);

/* Beat-local tonal probabilities from compressed tone groups 0 and 1. Each
   input contains pairs*12 words, in pair-major order; pairs is 1..19008.
   start/frames use the original (unpaired) feature-frame units. An interval
   beyond the supplied extent is clamped; fewer than two frames yields zeros.
   The production analysis pads both tone groups to the full 38016-frame
   window before calling this function. Output has 24 floats, root-major
   within each of two modes. Return the original selected class 0..23,
   or -1 for invalid input, leaving output unchanged. */
int negi_sensme_tonal_features(const uint16_t *amplitude, const uint16_t *logarithmic,
                              size_t pairs, size_t start, size_t frames, float *probabilities);

typedef struct {
    float milliseconds;
    int32_t bar, beat, tonal_class;
    float probabilities[24];
    float reserved_features[14];
} NegiSensMeBeat;
typedef struct {
    size_t preliminary_count, count;
    int32_t downbeat_offset;
    float downbeat_scores[4], aligned_phase_frames;
} NegiSensMeBeatGridSummary;
/* Default mono beat grid with tonal probabilities and downbeat alignment.
   Both tone inputs must contain the entire zero-padded 19008*12-word window.
   frames is a processed-frame count (0..38016, multiple of 128). Zero frames
   produces the original single diagnostic beat, not evidence of valid audio.
   period and phase are the float values from tempo_refine; rounding can leave
   phase equal to period, which is valid. Output capacity
   must accommodate the preliminary grid, capped at 960 records. Remaining
   analysis features are zero here; later classifiers fill them. Returns 1
   on success, 0 on invalid input/allocation failure, leaving outputs unchanged. */
int negi_sensme_beat_grid(const uint16_t *amplitude, const uint16_t *logarithmic,
                         size_t frames, float period, float phase, NegiSensMeBeat *beats,
                         size_t capacity, NegiSensMeBeatGridSummary *summary);

typedef struct {
    int32_t root;
    float probabilities[12];
} NegiSensMeSectionKey;
/* Segment-local root likelihoods from beat tonal classes, after segmentation.
   classes/sections/output each have count elements, count <=960. Classes are
   0..23; equal adjacent section labels define a segment. Reused labels in
   nonadjacent segments are handled independently. Output is repeated for each
   beat in its segment. Inputs/output must not overlap. Returns 1 on success
   (including count=0), or 0 on invalid input, leaving output unchanged. This
   function does not compute segment labels or final mood classification. */
int negi_sensme_section_keys(const int32_t *classes, const int32_t *sections, size_t count,
                            NegiSensMeSectionKey *output);

/* Numeric input to the remaining result classifiers. Internal research layout
   is versioned with this component; it is not an SMFMF payload. No pointers or
   platform handles are stored. Do not interpret this as completed analysis. */
typedef struct { uint32_t words[189]; } NegiSensMeResultFeatures;

/* Default final feature collection from an aligned grid, section-local keys
   and two 64-float track summaries (weighted first). All arrays are read-only;
   count is 1..960. Chorus index may equal count to omit its start timestamp.
   Returns 0 on invalid data, unrepresentable statistics, or more than 32
   collected section timestamps, leaving output unchanged. The last guard
   avoids the original routine's overlapping count-word write at capacity. */
int negi_sensme_result_features(const NegiSensMeBeat *beats, const NegiSensMeSectionKey *keys,
    const int32_t *sections, size_t count, const float *summaries, float bpm,
    float log_bpm, float spectrum_spread, int32_t chorus_type, size_t chorus_beat,
    NegiSensMeResultFeatures *output);

/* Default classifier scores from prepared result features. Selectors 25..64
   are the forty STHF models; 65..74 are the ten STMO models. Retains the
   original signed integer score without clamping to a percentage. Requires
   a finite stored BPM. Returns 1 on success, 0 for unsupported selector or
   invalid pointers/BPM, leaving output unchanged. Input is read-only. */
int negi_sensme_classification_score(const NegiSensMeResultFeatures *features,
                                    unsigned selector, int32_t *output);

typedef struct {
    const NegiSensMeResultFeatures *features;
    const NegiSensMeBeat *beats;
    const NegiSensMeSectionKey *keys;
    const int32_t *sections;
    size_t count;
    uint32_t processed_frames;
    float volume;
    int32_t chorus_type;
    size_t chorus_beat;
    uint32_t sample_offset;
} NegiSensMeEncodedInput;
/* Default 1.6.1 SMFMF formatting for the 44.1-kHz, stereo, 16-bit analysis
   input format. Includes GBPM/STBF/STSA/STMO/STHF/STMM when their original
   gates permit. Normalization is disabled, matching the current application.
   count is 0..960; nonempty input requires beat/key/section arrays. Input
   numeric features must be prepared separately. A zero-beat diagnostic may
   have no STMM and must not be treated as completed track analysis.
   NULL output queries the required byte count. Returns 0 for invalid input,
   allocation failure or insufficient capacity, leaving output unchanged.
   Input/output storage must not overlap. This formats results, not PCM. */
size_t negi_sensme_encode_smfmf(const NegiSensMeEncodedInput *input,
                               uint8_t *output, size_t capacity);

/* Default segment descriptors from compressed tone group 2 and beat times.
   tones has pairs*12 words, pair-major, with explicit end padding if needed;
   pairs is 1..38016. times has beats millisecond floats, beats is 2..960.
   Output contains floor(beats/2)*12 floats. Preserves original integer window
   boundaries and compressed scaling. Returns 0 if input storage is too short
   or invalid, with output unchanged; 1 on success. */
int negi_sensme_segment_vectors(const uint16_t *tones, size_t pairs, const float *times,
                                size_t beats, float *vectors);
/* Default 12-tone, two-beat-grouped self-similarity model. vectors has count*12
   floats in 0..2; count is 1..480. Output is a row-major (count-1)^2 uint16
   matrix. It does not assign section labels. No output is needed at count=1.
   Returns 1 on success, 0 on invalid input/allocation failure, with output
   unchanged. Retains original coarse means, quantization and search order. */
int negi_sensme_similarity_matrix(const float *vectors, size_t count, uint16_t *matrix);

/* Default greedy repeated-section search, before section/mood refinement.
   count is a beat count in 2..960; matrix has (floor(count/2)-1)^2 words from
   similarity_matrix. beat_numbers contains count original grid values 1..4.
   Output has count labels, -1 for unassigned beats, otherwise renumbered in
   first-appearance order. section_count receives the number of assigned types.
   The input matrix is retained. Returns 1 on success, 0 on invalid input or
   allocation failure, leaving output and section_count unchanged. */
int negi_sensme_coarse_sections(const uint16_t *matrix, size_t count, const int32_t *beat_numbers,
                               int32_t *output, size_t *section_count);

typedef struct {
    uint32_t start_beat, end_beat;
    int32_t section_type;
    float frequency, mean_position, mean_duration, raw_score, probability;
} NegiSensMeChorusRun;
typedef struct {
    int32_t section_type;
    uint32_t beat_index, scored_runs;
} NegiSensMeChorusSelection;
/* Default model score likelihood, including the measured reference policy for
   splitting and underflowing the integer exponent scale. If both exponents vanish, the original
   retains the input score, which may lie outside 0..1. Nonfinite input is
   retained. This helper does not classify an entire track. */
float negi_sensme_chorus_probability(float score);
/* Audited default 1.6.1 section/chorus selection. times/labels have count
   elements (2..960); times are increasing milliseconds within the analysis
   window, labels are -1 or 0..types-1, and each type must occur (types<=99).
   blocks is the weighted profile [16 means,16 deviations], block-major,
   block_count is 1..297. Missing trailing blocks in subranges are zero-padded.
   Optional type_scores has types floats; optional runs has count records,
   with the used prefix given by selection.scored_runs. Preserves the original
   unscored final run and independent type/beat choices. Other analysis-version
   branches are not implemented. Returns 1 on success (including no types),
   0 for invalid/unrepresentable input, leaving outputs unchanged. */
int negi_sensme_chorus_select(const float *times, const int32_t *labels, size_t count, size_t types,
                             const float *blocks, size_t block_count, NegiSensMeChorusSelection *selection,
                             float *type_scores, NegiSensMeChorusRun *runs);

typedef struct NegiSensMeAnalyzer NegiSensMeAnalyzer;
typedef struct {
    uint64_t input_frames, leading_zero_frames;
    size_t processed_frames, beat_count, descriptor_padding_pairs;
    int is_short, has_bpm;
    float bpm;
} NegiSensMeAnalyzerSummary;
/* Experimental composition of the verified default 1.6.1 stages. Input is
   44100-Hz signed stereo16; no normalization, decoder, file I/O or source writes.
   One instance per analysis; instances own their scratch and may run in parallel.
   The descriptor tail is explicitly zero-padded, never read beyond storage.
   Application entry and full-library validation are separate integration work. */
NegiSensMeAnalyzer *negi_sensme_analyzer_create(void);
void negi_sensme_analyzer_destroy(NegiSensMeAnalyzer *state);
/* Submit 0..65536 stereo frames per call, preserving original InputPCM call
   boundaries when comparing legacy bytes. Invalid arguments leave state alone;
   processing failure poisons the instance. Caller input is retained. */
int negi_sensme_analyzer_write(NegiSensMeAnalyzer *state, const int16_t *stereo, size_t frames);
/* True until the maximum 297 complete statistics blocks have been collected.
   The caller may finish early at EOF; a zero-input analysis cannot be finished. */
int negi_sensme_analyzer_needs_pcm(const NegiSensMeAnalyzer *state);
/* Static diagnostic stage after a processing/finalization failure, or NULL.
   The pointer is borrowed and never contains paths or audio data. */
const char *negi_sensme_analyzer_error(const NegiSensMeAnalyzer *state);
/* Finalize once and cache the default SMFMF bytes. NULL output queries size.
   A successful query seals input; subsequent calls retrieve the same bytes.
   Returns 0 on failure/insufficient capacity, retaining output and summary.
   Short diagnostics omit GBPM; summary.bpm is zero and has_bpm is false even
   though intermediate tempo arithmetic produces a value. Storage must not
   overlap state/input. This API does not label an existing Sony cache native. */
size_t negi_sensme_analyzer_finish(NegiSensMeAnalyzer *state, uint8_t *output, size_t capacity,
                                  NegiSensMeAnalyzerSummary *summary);

#ifdef __cplusplus
}
#endif
#endif
