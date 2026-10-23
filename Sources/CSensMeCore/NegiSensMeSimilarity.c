#include "NegiSensMeCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

static float as_float(uint32_t bits) { float value;memcpy(&value,&bits,4);return value; }

int negi_sensme_segment_vectors(const uint16_t *tones,size_t pairs,const float *times,
                                size_t beats,float *vectors) {
    if (!tones || !times || !vectors || pairs>38016 || !pairs || beats<2 || beats>960) return 0;
    const float rate=as_float(0x3e022391);
    size_t count=beats/2,starts[480],lengths[480];
    for (size_t i=0;i<beats;i++) if (!isfinite(times[i]) || times[i]<0 || times[i]>300000) return 0;
    double window=count>1 ? ((double)times[2]-times[0])*rate : 100;
    if (window<0 || window>76032) return 0;
    size_t frames=(size_t)window;
    for (size_t i=0;i<count;i++) {
        starts[i]=(size_t)((double)times[i*2]*rate)/2;
        // Preserve the original comparison's unpaired window extent. Actual
        // reads still consume pairs. Reject missing input rather than reading
        // beyond the caller's explicitly padded compressed-tone storage.
        size_t used=frames;
        if (starts[i]+used>38016) used=starts[i]<38016 ? 38016-starts[i] : 0;
        lengths[i]=used/2;
        if (starts[i]>pairs || lengths[i]>pairs-starts[i]) return 0;
    }
    for (size_t i=0;i<count;i++) for (size_t tone=0;tone<12;tone++) {
        double sum=0;
        for (size_t pair=0;pair<lengths[i];pair++)
            sum+=(double)tones[(starts[i]+pair)*12+tone]/32768;
        vectors[i*12+tone]=lengths[i] ? (float)(sum/(double)lengths[i]) : 0;
    }
    return 1;
}

static float best_correlation(const float *vectors,size_t count,size_t left,size_t right,
                              float mean_left,float mean_right,const float *norms) {
    size_t width=count-right;
    if (width>8) width=8;
    float best=0;
    for (size_t shift=0;shift<12;shift++) {
        double sum=0;
        for (size_t row=0;row<width;row++) for (size_t tone=0;tone<12;tone++)
            sum+=((double)vectors[(left+row)*12+tone]-mean_left)*
                 ((double)vectors[(right+row)*12+(tone+shift)%12]-mean_right);
        if (norms[left]>0 && norms[right]>0) sum/=(double)norms[left]*norms[right];
        if (best<sum) best=(float)sum;
    }
    return best;
}

static uint16_t quantize(float value) {
    double scaled=(double)value*65535;
    // The original ftol helper converts to signed 64-bit and the caller keeps
    // its low 16 bits. Overflow yields the integer-indefinite low word, zero.
    return scaled>=0 && scaled<0x1p63 ? (uint16_t)(uint64_t)scaled : 0;
}

static uint16_t likelihood(uint16_t value) {
    double x=(double)value*as_float(0x37800080);
    double da=x-as_float(0x3f553162),db=x-as_float(0x3ee3162d);
    double a=exp(da*da*as_float(0xc2517613)),b=exp(db*db*as_float(0xc1ca308e));
    return (uint16_t)(uint32_t)((a/(a+b))*65535);
}

int negi_sensme_similarity_matrix(const float *vectors,size_t count,uint16_t *matrix) {
    if (!vectors || count<1 || count>480 || (count>1 && !matrix)) return 0;
    for (size_t i=0;i<count*12;i++) if (!isfinite(vectors[i]) || vectors[i]<0 || vectors[i]>2) return 0;
    if (count==1) return 1;
    float means[480],norms[480];size_t side=count-1;
    uint16_t *scratch=calloc(side*side,sizeof(*scratch));
    if (!scratch) return 0;
    for (size_t row=0;row<count;row++) {
        size_t width=count-row;if (width>8) width=8;
        double sum=0,squared=0;
        for (size_t i=0;i<width*12;i++) sum+=vectors[row*12+i];
        means[row]=(float)(sum/(double)(width*12));
        for (size_t i=0;i<width*12;i++) { double delta=(double)vectors[row*12+i]-means[row];squared+=delta*delta; }
        norms[row]=(float)sqrt(squared);
    }
    const size_t step=11; // Default 23-beat search stride, grouped by two beats.
    for (size_t left=0;left<side;left+=step) for (size_t right=left+1;right<side;right++)
        scratch[left*side+right]=quantize(best_correlation(vectors,count,left,right,means[left],means[right],norms));
    for (size_t left=0;left<side;left+=step) for (size_t right=left+1;right<side;right++) {
        float gate=(float)((double)scratch[left*side+right]*as_float(0x37800080));
        for (size_t offset=1;offset<step;offset++) {
            if (gate<=as_float(0x3ee3162d) || left<=offset) break;
            size_t a=left-offset,b=right-offset;
            if (scratch[a*side+b]) break;
            // The reference deliberately retains the coarse anchor means.
            gate=best_correlation(vectors,count,a,b,means[left],means[right],norms);
            scratch[a*side+b]=quantize(gate);
        }
    }
    for (size_t left=0;left<side;left+=step) for (size_t right=left+1;right<side;right++) {
        float gate=(float)((double)scratch[left*side+right]*as_float(0x37800080));
        for (size_t offset=1;offset<step;offset++) {
            if (!(as_float(0x3e805401)<gate) || right+offset>=side) break;
            size_t a=left+offset,b=right+offset;
            if (scratch[a*side+b]) break;
            gate=best_correlation(vectors,count,a,b,means[left],means[right],norms);
            scratch[a*side+b]=quantize(gate);
        }
    }
    for (size_t left=0;left<side;left++) {
        scratch[left*side+left]=65535;
        for (size_t right=left+1;right<side;right++)
            scratch[right*side+left]=scratch[left*side+right]=likelihood(scratch[left*side+right]);
    }
    memcpy(matrix,scratch,side*side*sizeof(*matrix));free(scratch);return 1;
}
