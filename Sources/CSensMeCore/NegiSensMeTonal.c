#include "NegiSensMeCore.h"
#include <math.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

static float as_float(uint32_t bits) { float value;memcpy(&value,&bits,4);return value; }

static void mean_normalize(const uint16_t *input,size_t pairs,double scale,float *normalized) {
    float means[12];
    for (size_t tone=0;tone<12;tone++) {
        double sum=0;
        for (size_t pair=0;pair<pairs;pair++) sum+=(float)(input[pair*12+tone]*scale);
        means[tone]=(float)(sum/(double)pairs);
    }
    double sum=0,variance=0;
    for (int tone=0;tone<12;tone++) sum+=means[tone];
    float mean=(float)(sum/12.0);
    for (int tone=0;tone<12;tone++) { double delta=(double)means[tone]-mean;variance+=delta*delta; }
    float stored_variance=(float)(variance*(double)(1.0f/12));
    double gain=fabs(stored_variance)>0x1.5798ee2308c3ap-27 ? 1.0/sqrt((double)stored_variance) : 1;
    for (int tone=0;tone<12;tone++) normalized[tone]=(float)(((double)means[tone]-mean)*gain);
}

static float root_score(const float *x) {
    static const double w[10]={0x1.356fb7ffffffbp+5,0x1.0620c80000000p+1,
        0x1.06eda40000003p+3,0x1.4313b5ffffffdp-1,0x1.78b3400000004p-1,
        0x1.82788a0000004p+0,0x1.0267aa0000003p+0,0x1.d6fa8e0000009p+1,
        0x1.d3a859ffffff8p-2,0x1.932650000000dp+0};
    double result=x[4]*w[9]-x[11]*w[8];
    result+=x[7]*w[7];result-=x[9]*w[6];result-=x[8]*w[5];
    result+=x[3]*w[4];result-=x[2]*w[3];result+=x[0]*w[2];
    result-=x[5]*w[1];return (float)(result+w[0]);
}

static float mode_score(const float *x) {
    static const double w[10]={0x1.b24eb00000004p+5,0x1.ef60000000000p+0,
        0x1.e0f02e0000001p+0,0x1.7df3ba0000013p+0,0x1.78d771fffffecp+3,
        0x1.d025aa0000003p+1,0x1.1f19480000005p+2,0x1.bf4823ffffff7p+0,
        0x1.34b4d5ffffff7p+0,0x1.4f05960000005p+1};
    double sub=x[11]*w[8]+x[2]*w[7];sub+=x[4]*w[6];
    double result=x[1]*w[9]-sub;
    result+=x[10]*w[5];result+=x[3]*w[4];result+=x[0]*w[3];
    result+=x[7]*w[2];result+=x[6]*w[1];return (float)(result+w[0]);
}

static float likelihood(float input,uint32_t mean_a,uint32_t sigma_a,uint32_t mean_b,uint32_t sigma_b) {
    double da=(double)input-as_float(mean_a),db=(double)input-as_float(mean_b);
    double sa=as_float(sigma_a),sb=as_float(sigma_b);
    double a=exp(-(da*da)/(2*sa*sa)),b=exp(-(db*db)/(2*sb*sb));
    return a+b>0 ? (float)(a/(a+b)) : input;
}

int negi_sensme_tonal_features(const uint16_t *amplitude,const uint16_t *logarithmic,
                              size_t pairs,size_t start,size_t frames,float *probabilities) {
    if (!amplitude || !logarithmic || !probabilities || !pairs || pairs>19008 || start>pairs*2) return -1;
    if (frames>pairs*2-start) frames=pairs*2-start;
    float output[24]={0};int selected=0;
    if (frames>=2) {
        float roots[12],modes[12],rotated[12];
        mean_normalize(amplitude+start/2*12,frames/2,1.0/256,roots);
        mean_normalize(logarithmic+start/2*12,frames/2,1.0/32768,modes);
        for (int root=0;root<12;root++) {
            for (int tone=0;tone<12;tone++) rotated[tone]=roots[(root+tone)%12];
            output[root]=output[root+12]=likelihood(root_score(rotated),0x427eb790,0x40c9aa12,0x4211f943,0x40bebfe3);
            if (output[root]>output[selected]) selected=root;
        }
        // Selection intentionally follows the original incremental updates:
        // the current winner may still hold an unsplit root probability.
        for (int root=0;root<12;root++) {
            for (int tone=0;tone<12;tone++) rotated[tone]=modes[(root+tone)%12];
            float mode=likelihood(mode_score(rotated),0x428ddaed,0x4101a5ed,0x42242207,0x40c81e68);
            output[root]=(float)((1.0-(double)mode)*output[root]);
            output[root+12]=(float)((double)mode*output[root+12]);
            if (output[selected]<output[root]) selected=root;
            if (output[selected]<output[root+12]) selected=root+12;
        }
    }
    memcpy(probabilities,output,sizeof(output));return selected;
}
