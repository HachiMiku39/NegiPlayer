#include "NegiSensMeCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

enum { BINS=72, FRAMES=128, TONES=12, WINDOW=52, LIMIT=38016 };
struct NegiSensMeDynamics {
    float tone_weights[3][BINS], onset_weights[BINS];
    float history[WINDOW][BINS], previous[3];
    uint32_t window_sums[BINS];
    unsigned processed;
};

static float as_float(uint32_t bits) { float value; memcpy(&value,&bits,4); return value; }

NegiSensMeDynamics *negi_sensme_dynamics_create(void) {
    NegiSensMeDynamics *s=calloc(1,sizeof(*s));
    if (!s) return NULL;
    const uint32_t centers[3]={0x41b5af2b,0x423a7915,0x42334e27};
    const uint32_t widths[3]={0x410d3bba,0x412a0c94,0x40ef6cdf};
    for (unsigned group=0;group<3;group++) {
        double center=as_float(centers[group]),width=as_float(widths[group]);
        for (unsigned bin=0;bin<BINS;bin++) {
            double delta=bin-center;
            s->tone_weights[group][bin]=(float)exp(-delta*delta/(2*width*width));
        }
        for (unsigned tone=0;tone<TONES;tone++) {
            double sum=0;
            for (unsigned bin=tone;bin<BINS;bin+=TONES) sum+=s->tone_weights[group][bin];
            double inverse=1.0/sum;
            for (unsigned bin=tone;bin<BINS;bin+=TONES)
                s->tone_weights[group][bin]=(float)(inverse*s->tone_weights[group][bin]);
        }
    }
    for (unsigned bin=0;bin<BINS;bin++)
        s->onset_weights[bin]=(float)(12*pow((double)as_float(0x3fb6152c),bin*(double)as_float(0x3daaaaab)));
    return s;
}

void negi_sensme_dynamics_destroy(NegiSensMeDynamics *s) { free(s); }

int negi_sensme_dynamics_block(NegiSensMeDynamics *s, const uint16_t *input,
                                uint16_t *tones, float *onsets) {
    if (!s || !input || !tones || !onsets || s->processed>LIMIT-FRAMES) return 0;
    for (unsigned pair=0;pair<FRAMES/2;pair++) {
        float amplitude[BINS],logarithmic[BINS];
        for (unsigned bin=0;bin<BINS;bin++) {
            unsigned first=input[pair*2*BINS+bin],second=input[(pair*2+1)*BINS+bin];
            float a=(float)sqrt((double)first);
            a=(float)((double)a+sqrt((double)second));
            amplitude[bin]=0.5f*a;
            float l=first ? (float)(log((double)first)*0.125) : 0;
            if (second) l=(float)((double)l+log((double)second)*0.125);
            logarithmic[bin]=0.5f*l;
        }
        for (unsigned group=0;group<3;group++) {
            float projection[TONES]={0};
            const float *values=group ? logarithmic : amplitude;
            for (unsigned bin=0;bin<BINS;bin++) {
                unsigned tone=bin%TONES;
                projection[tone]=(float)((double)projection[tone]+(double)s->tone_weights[group][bin]*values[bin]);
            }
            double scale=group ? 32768.0 : 256.0;
            for (unsigned tone=0;tone<TONES;tone++)
                tones[(group*(FRAMES/2)+pair)*TONES+tone]=(uint16_t)(uint32_t)(scale*projection[tone]);
        }
    }
    const float decay=as_float(0x3e849170);
    const double mean_scale=(double)as_float(0x38d1b717)/WINDOW;
    const unsigned boundaries[4]={0,48,61,BINS};
    for (unsigned frame=0;frame<FRAMES;frame++) {
        unsigned index=s->processed+frame;
        float current[BINS];
        float *past=s->history[index%WINDOW];
        for (unsigned bin=0;bin<BINS;bin++) {
            current[bin]=(float)(sqrt((double)input[frame*BINS+bin])*0.5);
            // The original uses signed integer additions modulo 2^32. Store
            // unsigned words so the wrap is defined even on extreme input.
            s->window_sums[bin]+=(uint32_t)(int32_t)((double)current[bin]*current[bin]*10000);
            s->window_sums[bin]+=(uint32_t)(int32_t)((double)past[bin]*past[bin]*-10000);
        }
        for (unsigned band=0;band<3;band++) {
            double rise=0;
            for (unsigned bin=boundaries[band];bin<boundaries[band+1];bin++) {
                int32_t sum; memcpy(&sum,s->window_sums+bin,sizeof(sum));
                float mean=(float)((double)sum*mean_scale);
                double squared=(double)past[bin]*past[bin];
                if (sum>0 && mean<squared)
                    rise+=log(squared/mean)*s->onset_weights[bin];
            }
            float value=(float)((double)decay*s->previous[band]+(1.0-decay)*rise);
            s->previous[band]=value;
            onsets[band*FRAMES+frame]=index>=WINDOW ? value : 0;
        }
        memcpy(past,current,sizeof(current));
    }
    s->processed+=FRAMES;
    return 1;
}
