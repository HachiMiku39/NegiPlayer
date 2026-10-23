#include "NegiSensMeCore.h"
#include <math.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

static float as_float(uint32_t bits) { float value;memcpy(&value,&bits,4);return value; }

static float model_score(const float *s,const float *r,float frequency,float position,float duration) {
    // Exact binary64 parameters of the audited default 1.6.1 analysis model.
    static const double w[26]={0x1.8a02adffffff1p+3,0x1.c21594000000dp+7,
        0x1.e542f2000000fp+7,0x1.25e9edffffff1p+7,0x1.77cce1ffffffep+4,
        0x1.1606e7ffffffep+3,0x1.90ffadffffffep-2,0x1.83d85e0000000p+19,
        0x1.2f1b4e0000000p+14,0x1.62fb860000000p+18,0x1.0e357a0000000p+3,
        0x1.091be00000000p+7,0x1.ef5ec80000000p+1,0x1.1638c00000000p+5,
        0x1.63cedbffffffdp+1,0x1.8f49e00000001p+2,0x1.09dae7ffffffep+5,
        0x1.6f8c75ffffffcp+2,0x1.5f3a300000004p+4,0x1.ed9b3c0000004p+4,
        0x1.1defadffffffcp+2,0x1.8ae737ffffffbp+5,0x1.0bfa67ffffff9p+0,
        0x1.5af9980000007p+1,0x1.bc8274000001bp+3,0x1.1bc7820000008p+1};
    double value=r[48]*w[25]-r[42]*w[24];
    value+=r[36]*w[23];value+=r[13]*w[22];value-=s[60]*w[21];
    value-=r[54]*w[20];value+=r[0]*w[19];value-=s[11]*w[18];
    value+=s[10]*w[17];value-=r[9]*w[16];value+=r[8]*w[15];
    value-=s[0]*w[14];value+=r[43]*w[13];value-=r[30]*w[12];
    value-=s[49]*w[11];value+=s[45]*w[10];value-=s[36]*w[9];
    value-=s[21]*w[8];value-=s[5]*w[7];value+=duration*w[6];
    value+=position*w[5];value+=frequency*w[4];value+=s[48]*w[3];
    value+=s[33]*w[2];value-=s[40]*w[1];return (float)(value+w[0]);
}

static double reference_exp(double exponent) {
    // The audited reference splits exp into a nearest-integer binary exponent
    // and a fractional power. Its integer scale vanishes below -1022, while
    // the subsequent product can still be subnormal. Flushing the final value
    // instead would move the observed boundary by half a binary exponent.
    double binary=exponent*0x1.71547652b82fep+0;
    if (binary<-1022.5) return 0;
    double lower=floor(binary),fraction=binary-lower;int scale=(int)lower;
    if (fraction>0.5 || (fraction==0.5 && scale%2)) scale++;
    double residual=binary-scale;
    return ldexp(1,scale)*(1+expm1(residual*0x1.62e42fefa39efp-1));
}

float negi_sensme_chorus_probability(float score) {
    if (!isfinite(score)) return score;
    double a=(double)score-as_float(0x428526b9),b=(double)score-as_float(0x42349154);
    double sa=as_float(0x40b4449a),sb=as_float(0x4106e628);
    a=reference_exp(-(a*a)/(2*sa*sa));b=reference_exp(-(b*b)/(2*sb*sb));
    return a+b>0 ? (float)(a/(a+b)) : score;
}

int negi_sensme_chorus_select(const float *times,const int32_t *labels,size_t count,size_t types,
                             const float *blocks,size_t block_count,NegiSensMeChorusSelection *selection,
                             float *type_scores,NegiSensMeChorusRun *runs) {
    if (!times || !labels || !blocks || !selection || count<2 || count>960 || types>99 || block_count<1 || block_count>297) return 0;
    const float rate=as_float(0x3e022391);
    // Millisecond float round trips can lie just past the final frame. The
    // reference truncates frame coordinates; accept every coordinate whose
    // integer frame is still within the 38016-frame analysis window.
    for (size_t i=0;i<count;i++) if (!isfinite(times[i]) || times[i]<0 || (double)times[i]*rate>=38017 ||
        (i && times[i]<=times[i-1]) || labels[i]<-1 || (labels[i]>=0 && (size_t)labels[i]>=types)) return 0;
    for (size_t i=0;i<block_count*32;i++) if (!isfinite(blocks[i])) return 0;
    unsigned repeats[99]={0},maximum=1;
    for (size_t i=0;i<count;i++) if (labels[i]>=0 && (!i || labels[i]!=labels[i-1])) {
        unsigned n=++repeats[labels[i]];if (n>maximum) maximum=n;
    }
    for (size_t type=0;type<types;type++) if (!repeats[type]) return 0;
    NegiSensMeChorusSelection result={0};
    if (!types) { *selection=result;return 1; }
    float positions[99]={0},durations[99]={0},scores[99]={0};
    int previous=-1;size_t start=0;
    for (size_t i=0;i<count;i++) {
        if (labels[i]!=previous || i==count-1) {
            if (previous>=0) {
                positions[previous]=(float)((double)positions[previous]+((double)times[start]+times[i])*0.5/times[count-1]);
                durations[previous]=(float)((double)durations[previous]+((double)times[i]-times[start])*as_float(0x3a83126f));
            }
            previous=labels[i];if (previous>=0) start=i;
        }
    }
    for (size_t type=0;type<types;type++) {
        positions[type]=(float)((double)positions[type]/repeats[type]);
        durations[type]=(float)((double)durations[type]/repeats[type]);
    }
    float whole[64];
    if (!negi_sensme_spectral_summary(blocks,block_count,whole)) return 0;
    for (int i=0;i<64;i++) if (!isfinite(whole[i])) return 0;
    NegiSensMeChorusRun local_runs[960];size_t scored=0;
    previous=-1;start=0;float best_run=0;
    // No sentinel at count: the original does not score its final open run.
    for (size_t i=0;i<count;i++) if (labels[i]!=previous) {
        if (previous>=0) {
            size_t first_frame=(size_t)((double)times[start]*rate);
            size_t length=(size_t)(((double)times[i]-times[start])*rate);
            size_t first=first_frame/128,n=(first_frame+length)/128-first;
            if (!n) n=1;
            if (first>=297 || n>297-first) return 0;
            float input[297*32]={0},summary[64],ratios[64];
            for (size_t block=0;block<n;block++) if (first+block<block_count)
                memcpy(input+block*32,blocks+(first+block)*32,32*sizeof(float));
            if (!negi_sensme_spectral_summary(input,n,summary)) return 0;
            for (int column=0;column<64;column++) {
                ratios[column]=whole[column]>0 ? (float)((double)summary[column]/whole[column]) : 0;
                if (!isfinite(ratios[column]) || !isfinite(summary[column])) return 0;
            }
            float frequency=(float)((double)repeats[previous]/maximum);
            float raw=model_score(summary,ratios,frequency,positions[previous],durations[previous]);
            float value=negi_sensme_chorus_probability(raw);
            if (!isfinite(raw) || !isfinite(value)) return 0;
            local_runs[scored++]=(NegiSensMeChorusRun){(uint32_t)start,(uint32_t)i,previous,
                frequency,positions[previous],durations[previous],raw,value};
            if (value>=0 && value<=1) scores[previous]=(float)((double)scores[previous]+value);
            if (best_run<value) { best_run=value;result.section_type=previous;result.beat_index=(uint32_t)start; }
        }
        previous=labels[i];if (previous>=0) start=i;
    }
    float best_type=-100000000;
    for (size_t type=0;type<types;type++) {
        scores[type]=(float)((double)scores[type]/repeats[type]);
        if (best_type<scores[type]) { best_type=scores[type];result.section_type=(int32_t)type; }
    }
    result.scored_runs=(uint32_t)scored;
    if (type_scores) memcpy(type_scores,scores,types*sizeof(float));
    if (runs && scored) memcpy(runs,local_runs,scored*sizeof(*runs));
    *selection=result;return 1;
}
