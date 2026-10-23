#include "NegiSensMeCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF
_Static_assert(sizeof(NegiSensMeBeat)==168,"Beat layout must match the audited feature record");

static float correlation(const float *a,const float *b) {
    const float inverse=1.0f/24;
    double sa=0,sb=0,va=0,vb=0,covariance=0;
    for (int i=0;i<24;i++) { sa+=a[i];sb+=b[i]; }
    float ma=(float)((double)(float)sa*inverse),mb=(float)((double)(float)sb*inverse);
    for (int i=0;i<24;i++) {
        double da=(double)a[i]-ma,db=(double)b[i]-mb;
        va+=da*da;vb+=db*db;covariance+=da*db;
    }
    float variance_a=(float)((double)(float)va*inverse),variance_b=(float)((double)(float)vb*inverse);
    if (!(variance_a>0 && variance_b>0)) return 0;
    return (float)(((double)inverse*(float)covariance)/(sqrt((double)variance_a)*sqrt((double)variance_b)));
}

static void downbeat_features(const NegiSensMeBeat *beats,size_t count,size_t beat,float *features) {
    memset(features,0,20*sizeof(float));
    if (beat<2 || beat>=count-2) return;
    for (int i=0;i<16;i++) {
        int at=(int)beat-8+i;
        if (at>=0 && (size_t)at+1<count)
            features[i]=beats[at].tonal_class!=beats[at+1].tonal_class;
    }
    for (int i=0;i<2;i++)
        features[16+i]=correlation(beats[beat].probabilities,beats[beat-2+i].probabilities);
}

static double downbeat_score(const float *x) {
    static const double w[14]={0x1.b10baa0000003p+5,0x1.416e91ffffff6p+1,
        0x1.67dd81ffffff1p+0,0x1.7f7fc3ffffff0p+0,0x1.6d79a3ffffffdp+2,
        0x1.67afb9ffffffdp+1,0x1.2a77a00000002p-1,0x1.134e9e0000002p+1,
        0x1.836013ffffffep+1,0x1.184cb40000002p+2,0x1.02f383ffffffep+2,
        0x1.cafcd9ffffffbp+1,0x1.a945680000004p+2,0x1.a6941a0000004p+1};
    double result=x[11]*w[13]-x[17]*w[12];
    result-=x[0]*w[11];result+=x[18]*w[10];result-=x[16]*w[9];
    result+=x[15]*w[8];result-=x[9]*w[7];result-=x[7]*w[6];
    result-=x[4]*w[5];result+=x[3]*w[4];result-=x[13]*w[3];
    result-=x[2]*w[2];result-=x[6]*w[1];return result+w[0];
}

int negi_sensme_beat_grid(const uint16_t *amplitude,const uint16_t *logarithmic,
                         size_t frames,float period,float phase,NegiSensMeBeat *beats,
                         size_t capacity,NegiSensMeBeatGridSummary *summary) {
    if (!amplitude || !logarithmic || !beats || !summary || frames>38016 || frames%128 ||
        !isfinite(period) || !isfinite(phase) || period<1 || period>2147483647.0 || phase<0 || phase>period || phase>frames) return 0;
    size_t count=(size_t)(((double)frames-phase)/period)+1;
    if (count>960) count=960;
    if (capacity<count) return 0;
    NegiSensMeBeat *scratch=calloc(count,sizeof(*scratch));
    if (!scratch) return 0;
    uint32_t rate_bits=0x3e022391;float rate;memcpy(&rate,&rate_bits,4);
    for (size_t i=0;i<count;i++) {
        double start=i*(double)period+phase;
        scratch[i].milliseconds=(float)(start/rate);
        scratch[i].tonal_class=negi_sensme_tonal_features(amplitude,logarithmic,19008,(size_t)start,(size_t)period,scratch[i].probabilities);
        if (scratch[i].tonal_class<0) { free(scratch);return 0; }
    }
    NegiSensMeBeatGridSummary result={0};result.preliminary_count=count;
    for (size_t i=1;i+1<count;i++) {
        float features[20];downbeat_features(scratch,count,i,features);
        result.downbeat_scores[i%4]=(float)(downbeat_score(features)+result.downbeat_scores[i%4]);
    }
    float best=0;
    for (int i=0;i<4;i++) if (best<result.downbeat_scores[i]) {
        best=result.downbeat_scores[i];result.downbeat_offset=i;
    }
    size_t skip=(size_t)result.downbeat_offset;
    // A one-beat grid has no downbeat candidates, so skip remains zero.
    count-=skip;memmove(scratch,scratch+skip,count*sizeof(*scratch));
    float aligned_phase=(float)((double)skip*period+phase);
    for (size_t i=0;i<count;i++) {
        scratch[i].milliseconds=(float)((i*(double)period+aligned_phase)/rate);
        // Preserve the original bar numbering (the first complete bar is 2).
        scratch[i].bar=(int32_t)(i/4+2);scratch[i].beat=(int32_t)(i%4+1);
        if (i%2==0) {
            float peak=0;int selected=0;
            for (int tone=0;tone<24;tone++) {
                double score=scratch[i].probabilities[tone];
                if (i+1<count) score+=(double)scratch[i+1].probabilities[tone]*0.5;
                if (peak<score) { peak=(float)score;selected=tone; }
            }
            scratch[i].tonal_class=selected;
            if (i+1<count) scratch[i+1].tonal_class=selected;
        }
    }
    result.count=count;result.aligned_phase_frames=aligned_phase;
    memcpy(beats,scratch,count*sizeof(*beats));*summary=result;free(scratch);return 1;
}
