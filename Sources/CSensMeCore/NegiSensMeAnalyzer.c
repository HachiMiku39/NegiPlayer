#include "NegiSensMeCore.h"
#include <stdlib.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

enum { WINDOW=38016, PAIRS=WINDOW/2, BLOCKS=WINDOW/128, INPUT_LIMIT=65536 };
struct NegiSensMeAnalyzer {
    NegiSensMeFeatures *features;
    NegiSensMeSpectralStats *spectral[2];
    NegiSensMeDynamics *dynamics;
    NegiSensMePCMState pcm;
    uint64_t input_frames;
    size_t raw_frames, energy_count, blocks;
    int failed;
    const char *error;
    int16_t mono[INPUT_LIMIT];
    uint16_t energy[128*72];
    // The legacy descriptor checks unpaired extents while indexing pairs.
    // Provide an explicit zero tail for every permitted descriptor read.
    uint16_t tones[3][WINDOW*12];
    float stats[2][BLOCKS*32], onsets[3][WINDOW];
    uint8_t *encoded;
    size_t encoded_size;
    NegiSensMeAnalyzerSummary summary;
};
typedef struct {
    NegiSensMeBeat beats[960];
    NegiSensMeSectionKey keys[960];
    int32_t numbers[960], classes[960], sections[960];
    float times[960], vectors[480*12];
} FinalScratch;

static int accept_frame(void *context,const uint16_t *frame) {
    NegiSensMeAnalyzer *s=context;
    if(s->raw_frames++<negi_sensme_features_startup_frames() || s->blocks==BLOCKS)return 1;
    memcpy(s->energy+s->energy_count++*72,frame,144);
    if(s->energy_count<128)return 1;
    for(int profile=0;profile<2;profile++)
        if(!negi_sensme_spectral_block(s->spectral[profile],s->energy,
            s->stats[profile]+s->blocks*32,s->stats[profile]+s->blocks*32+16,NULL))return 0;
    uint16_t tones[3*64*12];float onsets[3*128];
    if(!negi_sensme_dynamics_block(s->dynamics,s->energy,tones,onsets))return 0;
    for(size_t group=0;group<3;group++) {
        memcpy(s->tones[group]+s->blocks*64*12,tones+group*64*12,64*12*2);
        for(size_t frame_index=0;frame_index<128;frame_index++) {
            size_t at=s->blocks*128+frame_index;
            if(at>=52)s->onsets[group][at-52]=onsets[group*128+frame_index];
        }
    }
    s->blocks++;s->energy_count=0;return 1;
}

void negi_sensme_analyzer_destroy(NegiSensMeAnalyzer *s) {
    if(!s)return;
    negi_sensme_features_destroy(s->features);
    for(int i=0;i<2;i++)negi_sensme_spectral_destroy(s->spectral[i]);
    negi_sensme_dynamics_destroy(s->dynamics);free(s->encoded);free(s);
}

NegiSensMeAnalyzer *negi_sensme_analyzer_create(void) {
    NegiSensMeAnalyzer *s=calloc(1,sizeof(*s));if(!s)return NULL;
    s->features=negi_sensme_features_create_default(accept_frame,s);
    s->spectral[0]=negi_sensme_spectral_create(1);s->spectral[1]=negi_sensme_spectral_create(0);
    s->dynamics=negi_sensme_dynamics_create();
    if(!s->features || !s->spectral[0] || !s->spectral[1] || !s->dynamics) {
        negi_sensme_analyzer_destroy(s);return NULL;
    }
    return s;
}

int negi_sensme_analyzer_needs_pcm(const NegiSensMeAnalyzer *s) {
    return s && !s->failed && !s->encoded && s->blocks<BLOCKS;
}

const char *negi_sensme_analyzer_error(const NegiSensMeAnalyzer *s) { return s ? s->error : "invalid_state"; }

int negi_sensme_analyzer_write(NegiSensMeAnalyzer *s,const int16_t *input,size_t frames) {
    if(!s || s->failed || s->encoded || frames>INPUT_LIMIT || (frames && !input) ||
        frames>UINT64_MAX-s->input_frames)return 0;
    if(!frames)return 1;
    s->input_frames+=frames;
    // Once saturated, future PCM cannot change the fixed analysis window.
    if(s->blocks==BLOCKS)return 1;
    size_t count=negi_sensme_prepare_pcm(&s->pcm,input,frames,2,s->mono);
    if(count==SIZE_MAX){s->failed=1;s->error="pcm_preparation";return 0;}
    for(size_t at=0;at<count;at+=4096) {
        size_t n=count-at;if(n>4096)n=4096;
        if(!negi_sensme_features_write(s->features,s->mono+at,n)){s->failed=1;s->error="energy_or_statistics";return 0;}
        if(s->blocks==BLOCKS)break;
    }
    return 1;
}

static int prepare_result(NegiSensMeAnalyzer *s,FinalScratch *work) {
    size_t frames=s->blocks*128;
    int32_t candidates[30]={0};float profile[256]={0},spread=0,volume=0,summaries[128];
    s->error="spectral_summary";
    for(int i=0;i<2;i++)
        if(!negi_sensme_spectral_summary(s->stats[i],s->blocks,summaries+i*64))return 0;
    // The reference's zero-block amplitude mean is NaN and is never serialized
    // by its short gate. Keep the omitted local value finite in the public API.
    s->error="volume";
    if(frames && !negi_sensme_spectral_volume(s->spectral[0],&volume))return 0;
    size_t segments=frames/4096;if(!segments)segments=1;
    s->error="fft_or_tempo_spectrum";
    NegiSensMeFFT *fft=negi_sensme_fft_create(4096);if(!fft)return 0;
    // One candidate persists through the reference's band-major traversal,
    // including spectra whose coarse search has no positive energy.
    int success=1,last_candidate=0;
    for(size_t band=0;band<3 && success;band++)for(size_t segment=0;segment<segments && success;segment++) {
        float source[4096]={0},packed[4096],magnitudes[2049];
        size_t start=segment*4096,n=frames-start;if(n>4096)n=4096;
        memcpy(source,s->onsets[band]+start,n*4);
        if(!negi_sensme_fft_real(fft,source,packed)){success=0;break;}
        candidates[segment*3+band]=last_candidate=negi_sensme_tempo_candidate_seeded(packed,magnitudes,last_candidate);
        if(band==2 && !negi_sensme_tempo_spectrum_accumulate(magnitudes,profile))success=0;
    }
    negi_sensme_fft_destroy(fft);if(!success)return 0;
    s->error="allocation";
    float *onsets=malloc((frames ? frames*3 : 1)*sizeof(float));if(!onsets)return 0;
    for(int i=0;i<3;i++)memcpy(onsets+i*frames,s->onsets[i],frames*sizeof(float));
    NegiSensMeTempoEstimate tempo;
    s->error="tempo_refinement";
    success=negi_sensme_tempo_spectrum_spread(profile,&spread) &&
        negi_sensme_tempo_refine(candidates,segments*3,onsets,frames,s->stats[0],&tempo,NULL);
    free(onsets);if(!success)return 0;
    NegiSensMeBeatGridSummary grid;
    s->error="beat_grid";
    if(!negi_sensme_beat_grid(s->tones[0],s->tones[1],frames,tempo.period_frames,tempo.phase_frames,
        work->beats,960,&grid))return 0;
    size_t count=grid.count,types=0,padding=0;
    for(size_t i=0;i<count;i++) {
        work->times[i]=work->beats[i].milliseconds;work->numbers[i]=work->beats[i].beat;
        work->classes[i]=work->beats[i].tonal_class;work->sections[i]=count==1 ? 0 : -1;
    }
    if(count>=2) {
        size_t groups=count/2,side=groups-1;
        uint16_t *matrix=calloc(side*side+1,sizeof(*matrix));if(!matrix)return 0;
        s->error="segmentation";
        success=negi_sensme_segment_vectors(s->tones[2],WINDOW,work->times,count,work->vectors) &&
            negi_sensme_similarity_matrix(work->vectors,groups,matrix) &&
            negi_sensme_coarse_sections(matrix,count,work->numbers,work->sections,&types);
        free(matrix);if(!success)return 0;
        uint32_t rate_bits=0x3e022391;float rate;memcpy(&rate,&rate_bits,4);
        size_t window=groups>1 ? (size_t)(((double)work->times[2]-work->times[0])*rate) : 100;
        for(size_t i=0;i<groups;i++) {
            size_t start=(size_t)((double)work->times[i*2]*rate)/2,used=window;
            if(start+used>WINDOW)used=start<WINDOW ? WINDOW-start : 0;
            size_t end=start+used/2;
            if(end>PAIRS && end-PAIRS>padding)padding=end-PAIRS;
        }
    }
    NegiSensMeChorusSelection chorus={0};
    s->error="chorus_selection";
    if(count>=2 && !negi_sensme_chorus_select(work->times,work->sections,count,types,s->stats[0],
        s->blocks,&chorus,NULL,NULL))return 0;
    NegiSensMeResultFeatures result;
    s->error="section_keys";
    if(!negi_sensme_section_keys(work->classes,work->sections,count,work->keys))return 0;
    s->error="result_features";
    if(!negi_sensme_result_features(work->beats,work->keys,work->sections,count,summaries,tempo.bpm,
        tempo.predicted_log_bpm,spread,chorus.section_type,chorus.beat_index,&result))return 0;
    NegiSensMeEncodedInput input={&result,work->beats,work->keys,work->sections,count,(uint32_t)frames,
        volume,chorus.section_type,chorus.beat_index,(uint32_t)s->pcm.leading_zero_frames};
    s->error="encoding";
    size_t bytes=negi_sensme_encode_smfmf(&input,NULL,0);if(!bytes)return 0;
    uint8_t *encoded=malloc(bytes);if(!encoded)return 0;
    if(negi_sensme_encode_smfmf(&input,encoded,bytes)!=bytes){free(encoded);return 0;}
    s->encoded=encoded;s->encoded_size=bytes;
    int is_short=frames<3802;
    s->summary=(NegiSensMeAnalyzerSummary){s->input_frames,s->pcm.leading_zero_frames,frames,count,padding,
        is_short,!is_short && tempo.bpm>0,is_short ? 0 : tempo.bpm};
    s->error=NULL;
    return 1;
}

size_t negi_sensme_analyzer_finish(NegiSensMeAnalyzer *s,uint8_t *output,size_t capacity,
                                  NegiSensMeAnalyzerSummary *summary) {
    if(!s || s->failed || !s->input_frames)return 0;
    if(!s->encoded) {
        FinalScratch *work=calloc(1,sizeof(*work));
        if(!work){s->error="allocation";return 0;}
        int success=prepare_result(s,work);free(work);
        if(!success){s->failed=1;return 0;}
    }
    if(output && capacity<s->encoded_size)return 0;
    if(output)memcpy(output,s->encoded,s->encoded_size);
    if(summary)*summary=s->summary;
    return s->encoded_size;
}
