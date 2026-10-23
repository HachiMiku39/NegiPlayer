#include "NegiSensMeCore.h"
#include <math.h>
#include <stdlib.h>

#pragma STDC FP_CONTRACT OFF

int negi_sensme_tempo_candidate_seeded(const float *packed,float *magnitudes,int previous) {
    if (!packed || previous<0 || previous>2047) return -1;
    float local[2049];float *spectrum=magnitudes ? magnitudes : local;
    spectrum[0]=packed[0];spectrum[2048]=packed[1];
    for (int i=1;i<2048;i++) {
        double real=packed[2*i],imaginary=packed[2*i+1];
        float squared=(float)(real*real+imaginary*imaginary);
        spectrum[i]=squared>0 ? (float)sqrt((double)squared) : squared;
    }
    float maximum=0;int candidate=previous;
    // Default octave range, with three weighted subharmonic neighborhoods.
    for (int bin=128;bin<512;bin++) {
        double score=0;
        if (spectrum[bin]>0) {
            score=spectrum[bin];
            for (unsigned level=1;level<=3;level++) {
                int center=bin>>level;
                for (int offset=-1;offset<=1;offset++) {
                    int at=center+offset;
                    if (at>0 && at<2048 && spectrum[at]>0) {
                        double weight=(double)0.6f-abs(offset)*(double)0.4f;
                        score+=weight*spectrum[at];
                    }
                }
            }
        }
        if (maximum<score) { maximum=(float)score;candidate=bin*2; }
    }
    while (candidate>2047) candidate/=2;
    maximum=0;
    if (candidate>=4 && candidate+4<2047) {
        int end=candidate+4;
        for (int bin=candidate-4;bin<=end;bin++)
            if (maximum<spectrum[bin]) { maximum=spectrum[bin];candidate=bin; }
    }
    return candidate;
}

int negi_sensme_tempo_candidate(const float *packed,float *magnitudes) {
    return negi_sensme_tempo_candidate_seeded(packed,magnitudes,0);
}
