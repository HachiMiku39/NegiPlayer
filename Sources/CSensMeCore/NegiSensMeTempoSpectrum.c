#include "NegiSensMeCore.h"
#include <math.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

int negi_sensme_tempo_spectrum_accumulate(const float *magnitudes,float *profile) {
    if (!magnitudes || !profile) return 0;
    float result[256];memcpy(result,profile,sizeof(result));
    for (int i=0;i<256;i++) if (!isfinite(result[i]) || result[i]<0) return 0;
    for (int bin=1;bin<2048;bin++) {
        if (!isfinite(magnitudes[bin]) || magnitudes[bin]<0) return 0;
        int index=(int)(32*log2(bin*0.125));
        // Original ln(x)/ln(256)*256 falls just below the integer at these
        // three positive boundaries. Verified against all 2047 input bins;
        // retain its conversion result instead of changing the energy bins.
        if (bin==64 || bin==512 || bin==1024) index--;
        if (index>=0 && index<256) {
            result[index]=(float)((double)result[index]+magnitudes[bin]);
            if (!isfinite(result[index])) return 0;
        }
    }
    memcpy(profile,result,sizeof(result));return 1;
}

int negi_sensme_tempo_spectrum_spread(const float *profile,float *spread) {
    if (!profile || !spread) return 0;
    for (int i=0;i<256;i++) if (!isfinite(profile[i]) || profile[i]<0) return 0;
    double sum=0,weighted=0;
    for (int i=0;i<246;i++) {
        sum+=profile[i+10];weighted+=(double)i*profile[i+10];
    }
    float denominator=(float)sum;
    if (!isfinite(denominator)) return 0;
    float mean=sum>0 ? (float)(weighted/sum) : 0.5f;
    double variance=0;
    for (int i=0;i<246;i++) {
        double delta=(double)i-mean;
        variance+=(delta*profile[i+10])*delta;
    }
    double value=denominator>0 ? sqrt(variance/denominator)/245 : 0;
    if (!isfinite(value)) return 0;
    *spread=(float)value;return 1;
}
