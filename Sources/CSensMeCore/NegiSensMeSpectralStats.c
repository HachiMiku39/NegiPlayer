#include "NegiSensMeCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

enum { BINS = 72, FRAMES = 128, STREAMS = 16, A = 0, C = 1, D = 2, E = 3, F = 4 };
typedef struct { float center, width, decay; unsigned log_domain; } Shape;
struct NegiSensMeSpectralStats {
    Shape shapes[5];
    float weights[5][BINS], amplitude[5][BINS], logarithmic[5][BINS];
    float history_amplitude[6][BINS], history_logarithmic[6][BINS];
    float gate[BINS], previous_bands[2], amplitude_sum;
    float peak_offset, gate_offset;
    unsigned low_boundary, high_boundary, lag, radius;
    size_t processed_frames;
};

static float bits_float(uint32_t bits) { float value; memcpy(&value,&bits,4); return value; }

NegiSensMeSpectralStats *negi_sensme_spectral_create(int weighted) {
    if (weighted != 0 && weighted != 1) return NULL;
    NegiSensMeSpectralStats *s = calloc(1,sizeof(*s));
    if (!s) return NULL;
    if (weighted) {
        s->shapes[A] = (Shape){60,72,bits_float(0x3f7851ec),1};
        s->shapes[C] = (Shape){81,14,bits_float(0x3dc08312),1};
        s->shapes[D] = (Shape){56,72,bits_float(0x3df1a9fc),0};
        s->shapes[E] = (Shape){65,bits_float(0x428cc28f),bits_float(0x3f3a1cac),0};
        s->shapes[F] = (Shape){26,41,bits_float(0x3e978d50),0};
        s->peak_offset = bits_float(0x3eb4bc6a);
        s->gate_offset = bits_float(0xbde76c8b);
        s->low_boundary = 24; s->high_boundary = 48;
        s->lag = 5; s->radius = 4;
    } else {
        for (int i=0;i<5;i++) s->shapes[i] = (Shape){42,100,0,1};
        s->gate_offset = bits_float(0xbd5218eb);
        s->low_boundary = 20; s->high_boundary = 51;
        s->lag = 1; s->radius = 3;
    }
    for (int shape=0;shape<5;shape++) for (int bin=0;bin<BINS;bin++) {
        double offset = bin - (double)s->shapes[shape].center;
        double sigma = s->shapes[shape].width;
        s->weights[shape][bin] = (float)exp(-(offset*offset)/(2*sigma*sigma));
    }
    return s;
}

void negi_sensme_spectral_destroy(NegiSensMeSpectralStats *s) { free(s); }

int negi_sensme_spectral_volume(const NegiSensMeSpectralStats *s, float *output) {
    if (!s || !output || !s->processed_frames || s->processed_frames > INT32_MAX/BINS) return 0;
    float mean = (float)((double)s->amplitude_sum/(double)(s->processed_frames*BINS));
    float level = mean;
    if (mean > 0) level = (float)((log((double)mean)/0x1.62e42fefa39efp-1)*6);
    *output = level;return 1;
}

static const float *update_shape(NegiSensMeSpectralStats *s, int shape,
                                 const float *amplitude, const float *logarithmic) {
    double decay = s->shapes[shape].decay, gain = 1.0-decay;
    for (int bin=0;bin<BINS;bin++) {
        s->amplitude[shape][bin] = (float)(decay*s->amplitude[shape][bin]
            + gain*(double)amplitude[bin]*s->weights[shape][bin]);
        s->logarithmic[shape][bin] = (float)(decay*s->logarithmic[shape][bin]
            + gain*(double)logarithmic[bin]*s->weights[shape][bin]);
    }
    return s->shapes[shape].log_domain ? s->logarithmic[shape] : s->amplitude[shape];
}

static void reduction(const float *input, float *mean, float *deviation) {
    double sum=0, squares=0;
    for (int i=0;i<FRAMES;i++) sum+=input[i];
    *mean=(float)(sum/FRAMES);
    // The audited reducer stores its mean as float before calculating residuals.
    for (int i=0;i<FRAMES;i++) { double delta=(double)input[i]-*mean; squares+=delta*delta; }
    *deviation=(float)sqrt(squares/(FRAMES-1));
}

int negi_sensme_spectral_summary(const float *blocks, size_t count, float *summary) {
    if (!summary || (count && !blocks) || count > SIZE_MAX/(32*sizeof(float))) return 0;
    if (!count) { memset(summary,0,64*sizeof(float)); return 1; }
    for (size_t column=0;column<32;column++) {
        double sum=0,squares=0;
        for (size_t block=0;block<count;block++) sum+=blocks[block*32+column];
        float mean=(float)(sum/(double)count);
        for (size_t block=0;block<count;block++) {
            double delta=(double)blocks[block*32+column]-mean;
            squares+=delta*delta;
        }
        if (count>2) squares/=(double)(count-1);
        size_t offset=column<16 ? column : column+16;
        summary[offset]=mean;
        summary[offset+16]=(float)sqrt(squares);
    }
    return 1;
}

int negi_sensme_spectral_block(NegiSensMeSpectralStats *s, const uint16_t *input,
                                float *means, float *deviations, float *series) {
    if (!s || !input || !means || !deviations || s->processed_frames > SIZE_MAX-FRAMES) return 0;
    float local[STREAMS*FRAMES];
    float *out=series ? series : local;
    const float inverse_bins=1.0f/BINS;
    // This reciprocal stays in the original x87 stack; unlike inverse_bins it
    // is never stored as float before the correlation means are calculated.
    const double inverse_interior=1.0/(BINS-2);
    for (int frame=0;frame<FRAMES;frame++) {
        float amplitude[BINS], logarithmic[BINS];
        for (int bin=0;bin<BINS;bin++) {
            unsigned value=input[frame*BINS+bin];
            amplitude[bin]=(float)sqrt((double)value);
            logarithmic[bin]=value ? (float)(log((double)value)*0.125) : 0;
            s->amplitude_sum=(float)((double)s->amplitude_sum+amplitude[bin]);
        }
        const float *curve=update_shape(s,A,amplitude,logarithmic);
        float groups[3]={0};
        double total=0, outer_sums[2]={0};
        unsigned counts[3]={0};
        for (unsigned bin=0;bin<BINS;bin++) {
            unsigned group=bin<=s->low_boundary ? 0 : bin<=s->high_boundary ? 1 : 2;
            groups[group]=(float)((double)groups[group]+curve[bin]); counts[group]++;
            total+=curve[bin];
            if (group==0) outer_sums[0]+=curve[bin];
            else if (group==2) outer_sums[1]+=curve[bin];
        }
        for (int group=0;group<3;group++) groups[group]=(float)((double)groups[group]/counts[group]);
        float values[STREAMS]={0};
        values[0]=(float)(total*inverse_bins);
        values[1]=groups[2]-groups[1]; values[2]=groups[0]-groups[1]; values[3]=1;
        for (int band=0;band<2;band++) {
            // The outer-band sums stay in x87 registers during accumulation,
            // are stored as float, then divided and stored as float again.
            float rounded_sum=(float)outer_sums[band];
            float current=(float)((double)rounded_sum/counts[band==0 ? 0 : 2]);
            double delta=(double)s->previous_bands[band]-current;
            if (current>s->previous_bands[band]) values[4+band]=(float)(delta*delta);
            if (current<s->previous_bands[band]) values[6+band]=(float)(delta*delta);
            s->previous_bands[band]=current;
        }

        curve=update_shape(s,C,amplitude,logarithmic);
        double curve_sum=0;
        for (int bin=0;bin<BINS;bin++) curve_sum+=curve[bin];
        float threshold=(float)(curve_sum*inverse_bins+s->peak_offset);
        unsigned peaks=0, nonpeaks=0, above=0;
        double peak_sum=0, nonpeak_sum=0, curvature=0;
        for (int bin=1;bin<BINS-1;bin++) {
            if (curve[bin]>curve[bin-1] && curve[bin]>curve[bin+1]) {
                peaks++; peak_sum+=curve[bin];
                curvature+=((double)curve[bin]-curve[bin-1])+((double)curve[bin]-curve[bin+1]);
                if (curve[bin]>threshold) above++;
            } else { nonpeaks++; nonpeak_sum+=curve[bin]; }
        }
        values[8]=(float)(inverse_bins*above);
        if (peaks) {
            values[14]=(float)(curvature/peaks);
            if (nonpeaks) values[15]=(float)(peak_sum/peaks-nonpeak_sum/nonpeaks);
        }

        memmove(s->history_amplitude[1],s->history_amplitude[0],s->lag*BINS*sizeof(float));
        memmove(s->history_logarithmic[1],s->history_logarithmic[0],s->lag*BINS*sizeof(float));
        curve=update_shape(s,D,amplitude,logarithmic);
        memcpy(s->history_amplitude[0],s->amplitude[D],BINS*sizeof(float));
        memcpy(s->history_logarithmic[0],s->logarithmic[D],BINS*sizeof(float));
        if (frame>0) {
            const float *past=s->shapes[D].log_domain ? s->history_logarithmic[s->lag] : s->history_amplitude[s->lag];
            float current_means[3]={0}; double past_mean=0;
            for (int bin=0;bin<BINS-2;bin++) {
                past_mean+=past[bin+1];
                for (int column=0;column<3;column++) current_means[column]=(float)((double)current_means[column]+curve[bin+column]);
            }
            past_mean*=inverse_interior;
            for (int column=0;column<3;column++) current_means[column]*=inverse_interior;
            double past_squared=0; float current_squared[3]={0}, products[3]={0};
            for (int bin=1;bin<BINS-1;bin++) {
                double past_delta=(double)past[bin]-past_mean;
                past_squared+=past_delta*past_delta;
                for (int column=0;column<3;column++) {
                    double current_delta=(double)curve[bin+column-1]-current_means[column];
                    current_squared[column]=(float)((double)current_squared[column]+current_delta*current_delta);
                    products[column]=(float)((double)products[column]+current_delta*past_delta);
                }
            }
            if (past_squared>0) for (int column=0;column<3;column++) if (current_squared[column]>0)
                values[10+column]=(float)(products[column]/(sqrt(past_squared)*sqrt((double)current_squared[column])));
        }

        curve=update_shape(s,E,amplitude,logarithmic);
        float gate_factor=(float)exp((double)s->gate_offset);
        double gap=0;
        for (int bin=0;bin<BINS;bin++) {
            s->gate[bin]=s->shapes[E].log_domain ? s->gate[bin]+s->gate_offset : gate_factor*s->gate[bin];
            if (curve[bin]<=s->gate[bin]) gap+=(double)s->gate[bin]-curve[bin];
            else s->gate[bin]=curve[bin];
        }
        values[13]=(float)(gap*inverse_bins);

        update_shape(s,F,amplitude,logarithmic);
        // The audited mono profiles select this domain with the E flag.
        curve=s->shapes[E].log_domain ? s->logarithmic[F] : s->amplitude[F];
        double roughness=0;
        for (unsigned center=s->radius;center<BINS-s->radius;center++) {
            float minimum=100;
            for (unsigned bin=center-s->radius;bin<center+s->radius;bin++) if (curve[bin]<minimum) minimum=curve[bin];
            if (s->shapes[E].log_domain) roughness+=(double)curve[center]-minimum;
            else if (curve[center]>0) roughness+=(double)minimum/curve[center];
        }
        values[9]=(float)(roughness/(BINS-2*s->radius));
        for (int stream=0;stream<STREAMS;stream++) out[stream*FRAMES+frame]=values[stream];
    }
    for (int stream=0;stream<STREAMS;stream++) reduction(out+stream*FRAMES,means+stream,deviations+stream);
    s->processed_frames += FRAMES;
    return 1;
}
