#include "NegiSensMeCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

static float float_bits(uint32_t bits) { float value;memcpy(&value,&bits,4);return value; }

int negi_sensme_tempo_vote(const int32_t *candidates,size_t count,int32_t *votes) {
    if (!candidates || count<1 || count>30) return -1;
    for (size_t i=0;i<count;i++) if (candidates[i]<0 || candidates[i]>2047) return -1;
    int32_t local[30]={0};
    for (size_t i=0;i<count;i++) local[i]=candidates[i]!=0;
    for (size_t i=0;i<count;i++) for (size_t j=i+1;j<count;j++) {
        int32_t a=candidates[i],b=candidates[j];
        if (!a || !b) continue;
        if (a==b) { local[i]++;local[j]++; }
        if (abs(a/2-b)<2) { local[i]++;local[j]++; }
        if (abs(a-b/2)<2) { local[i]++;local[j]++; }
    }
    size_t best=0;
    for (size_t i=1;i<count;i++) if (local[i]>local[best]) best=i;
    if (votes) memcpy(votes,local,count*sizeof(*votes));
    return candidates[best];
}

static double initial_phase(const float *input,size_t count,double period) {
    double phase=0,stop=(double)count-15*period;
    float best=0;
    for (int offset=0;offset<stop;offset++) {
        double sum=0;float peak=0;int strongest=0;
        for (int beat=0;beat<15;beat++) {
            float value=input[(size_t)(offset+beat*period)];sum+=value;
            if (peak<value) { peak=value;strongest=beat; }
        }
        // Compare the wide sum with the previously stored float, as the
        // original does. Equal rounded scores can still update the phase.
        if (best<sum) { best=(float)sum;phase=offset+strongest*period; }
    }
    return phase;
}

static double pulse_score(const float *input,size_t count,double period,double phase,int include_zero) {
    double sum=0,limit=(double)count-1;size_t used=0;
    for (int beat=0;;beat++) {
        double at=beat*period+phase;
        if (!(at<limit)) break;
        if (at>0 || (include_zero && at==0)) { sum+=input[(size_t)at];used++; }
    }
    for (int beat=-1;;beat--) {
        double at=beat*period+phase;
        if (!(at>0)) break;
        if (at<limit) { sum+=input[(size_t)at];used++; }
    }
    return used ? sum/(double)used : sum;
}

static double refine_period(const float *input,size_t count,size_t segments,int candidate,
                             double period,double phase) {
    float best=0;double selected=period;
    for (int drift=-210;drift<=210;drift++) {
        double current=((double)drift/(float)segments+4096.0f)/(float)candidate;
        double score=pulse_score(input,count,current,phase,0);
        if (best<score) { best=(float)score;selected=current; }
    }
    return selected;
}

static double refine_phase(const float *input,size_t count,double period,double phase) {
    float best=0;int offset=(int)phase;double selected=phase;
    for (int step=0;step<period;step++,offset++) {
        double score=pulse_score(input,count,period,offset,1);
        if (best<score) { best=(float)score;selected=offset; }
    }
    return selected;
}

static double regression(const float *s) {
    // Recovered numerical parameters, represented as exact binary64 literals.
    static const double w[17]={ 0x1.8a3ca7ffffffep+5,0x1.3ceabfffffff8p+1,0x1.577dc9ffffff6p+1,0x1.5f9c04000000ap+4,0x1.a2bd180000000p+17,0x1.92a0edfffffffp+4,0x1.eeb2800000000p+5,0x1.199a81ffffffep+7,0x1.63ad35ffffffdp+6,0x1.7b72d5ffffffdp+6,0x1.0cacaa0000003p+5,0x1.cfa5420000005p+4,0x1.2b3877ffffffbp+5,0x1.075e27ffffffbp+2,0x1.7642940000004p+9,0x1.74ef0e0000006p+5,0x1.2e6b480000005p+5 };
    double value=s[14]*w[16]-(s[56]*w[14]+s[57]*w[15]);
    value-=s[11]*w[13];value+=s[9]*w[12];value-=s[0]*w[11];
    value-=s[58]*w[10];value-=s[50]*w[9];value+=s[48]*w[8];
    value-=s[32]*w[7];value+=s[46]*w[6];value-=s[41]*w[5];
    value+=s[38]*w[4];value+=s[16]*w[3];value+=s[12]*w[2];
    value+=s[44]*w[1];return value+w[0];
}

static float predicted_log_bpm(const float *blocks,size_t count,float rate) {
    int window=(int)((double)rate*30000.0f);
    size_t pieces=count*128/(size_t)window;
    if (!pieces) pieces=1;
    float total=0;
    for (size_t piece=0;piece<pieces;piece++) {
        size_t start=piece*(size_t)window,first=start/128;
        size_t n=(start+(size_t)window)/128-first;
        if (!n) n=1;
        float input[297*32]={0},summary[64];
        for (size_t i=0;i<n;i++) if (first+i<count) memcpy(input+i*32,blocks+(first+i)*32,32*sizeof(float));
        if (!negi_sensme_spectral_summary(input,n,summary)) return NAN;
        total=(float)((double)total+regression(summary)*(double)0.1f);
    }
    return (float)((double)total/(double)pieces);
}

int negi_sensme_tempo_refine(const int32_t *candidates,size_t candidate_count,
                            const float *onsets,size_t frames,const float *stats,
                            NegiSensMeTempoEstimate *estimate,float *weighted) {
    if (!candidates || !onsets || !stats || !estimate || frames>38016 || frames%128) return 0;
    size_t segments=frames/4096;
    if (!segments) segments=1;
    if (candidate_count!=segments*3) return 0;
    int candidate=negi_sensme_tempo_vote(candidates,candidate_count,NULL);
    if (candidate<0) return 0;
    for (size_t i=0;i<3*frames;i++) if (!isfinite(onsets[i])) return 0;
    for (size_t i=0;i<frames/128*32;i++) if (!isfinite(stats[i])) return 0;
    float *curve=weighted ? weighted : malloc((frames ? frames : 1)*sizeof(float));
    if (!curve) return 0;
    memset(curve,0,frames*sizeof(float));
    const float gains[3]={float_bits(0x3f531ba6),1,float_bits(0x3f06eb0e)};
    for (int band=0;band<3;band++) for (size_t i=0;i<frames;i++)
        curve[i]=(float)((double)gains[band]*onsets[band*frames+i]+curve[i]);
    for (size_t i=0;i<frames;i++) if (!isfinite(curve[i])) { if (!weighted) free(curve);return 0; }
    NegiSensMeTempoEstimate out={0};out.selected_candidate=candidate;
    if (!candidate) candidate=1;
    out.raw_period=4096.0/candidate;double period=out.raw_period;
    while (period<20) { period*=2;candidate=(int)(4096.0/period); }
    out.adjusted_candidate=candidate;out.initial_period=period;
    out.initial_phase=initial_phase(curve,frames,period);
    period=refine_period(curve,frames,segments,candidate,period,out.initial_phase);
    out.refined_period=period;out.first_phase=refine_phase(curve,frames,period,out.initial_phase);
    float rate=float_bits(0x3e022391);
    out.predicted_log_bpm=predicted_log_bpm(stats,frames/128,rate);
    if (!isfinite(out.predicted_log_bpm)) { if (!weighted) free(curve);return 0; }
    double bpm=(float)(((double)rate*60000.0f)/period),log_bpm=log(bpm);
    const double tolerance=0x1.62e42fefa39efp-2;
    while (log_bpm<out.predicted_log_bpm-tolerance && bpm<250.0f) {
        bpm*=2;period*=0.5;log_bpm+=(double)0.6931471824645996f;
    }
    while (log_bpm>out.predicted_log_bpm+tolerance && bpm>50.0f) {
        bpm*=0.5;period*=2;log_bpm-=(double)0.6931471824645996f;
    }
    out.bpm=(float)bpm;out.final_period=period;
    out.final_phase=refine_phase(curve,frames,period,out.first_phase);
    if (period<1) period=1;
    out.period_frames=(float)period;out.phase_frames=(float)fmod(out.final_phase,period);
    if (!weighted) free(curve);
    *estimate=out;return 1;
}
