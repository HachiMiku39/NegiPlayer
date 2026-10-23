#include "NegiSensMeCore.h"
#include <math.h>
#include <stdlib.h>

#pragma STDC FP_CONTRACT OFF

typedef struct { float r,i; } Complex;
struct NegiSensMeFFT { unsigned count; Complex *twiddles,*scratch; };

NegiSensMeFFT *negi_sensme_fft_create(size_t count) {
    if (count<2 || count>4096 || (count&(count-1))) return NULL;
    NegiSensMeFFT *s=calloc(1,sizeof(*s));
    if (!s) return NULL;
    s->count=(unsigned)count;
    s->twiddles=malloc(3*count*sizeof(Complex));
    s->scratch=malloc(count*sizeof(Complex));
    if (!s->twiddles || !s->scratch) { negi_sensme_fft_destroy(s); return NULL; }
    // The recovered table uses a float phase increment, rather than rounding
    // each full angle to float or using exact 2*pi/count twiddles.
    float phase=(float)(atan(1.0)*-2.0/count);
    for (unsigned i=0;i<3*count;i++) {
        double angle=i*(double)phase;
        s->twiddles[i]=(Complex){(float)cos(angle),(float)sin(angle)};
    }
    return s;
}

void negi_sensme_fft_destroy(NegiSensMeFFT *s) {
    if (s) { free(s->twiddles); free(s->scratch); free(s); }
}

static unsigned next_reversed(unsigned value,unsigned half) {
    value^=half;
    for (unsigned bit=half;value<bit;) { bit>>=1;value^=bit; }
    return value;
}

static void butterfly(Complex *data,unsigned index,unsigned quarter,
                      const Complex *first,const Complex *third,int diagonal) {
    Complex a=data[index],b=data[index+quarter],c=data[index+2*quarter],d=data[index+3*quarter];
    double dr=(double)a.r-b.r,di=(double)a.i-b.i;
    double er=(double)d.r-c.r,ei=(double)d.i-c.i;
    data[index]=(Complex){(float)((double)a.r+b.r),(float)((double)a.i+b.i)};
    data[index+2*quarter]=(Complex){(float)((double)c.r+d.r),(float)((double)c.i+d.i)};
    double br=dr-ei,bi=er+di,cr=ei+dr,ci=di-er;
    if (diagonal) {
        double scale=first->r;
        data[index+quarter]=(Complex){(float)((bi+br)*scale),(float)((bi-br)*scale)};
        // The third branch spills this sum to float before the diagonal
        // rotation; retaining the full intermediate changes later bins.
        cr=(float)cr;
        data[index+3*quarter]=(Complex){(float)((ci-cr)*scale),(float)((-ci-cr)*scale)};
    } else if (first) {
        data[index+quarter]=(Complex){(float)(first->r*br-first->i*bi),(float)(first->i*br+first->r*bi)};
        cr=(float)cr;
        data[index+3*quarter]=(Complex){(float)(third->r*cr-third->i*ci),(float)(third->i*cr+third->r*ci)};
    } else {
        data[index+quarter]=(Complex){(float)br,(float)bi};
        data[index+3*quarter]=(Complex){(float)cr,(float)ci};
    }
}

static void group(Complex *data,unsigned base,unsigned quarter,
                  const Complex *first,const Complex *third,int diagonal) {
    for (unsigned stride=quarter;stride;stride>>=2)
        for (unsigned i=quarter-stride;i<quarter-(stride>>1);i++)
            butterfly(data,base+i,quarter,first,third,diagonal);
}

int negi_sensme_fft_real(NegiSensMeFFT *s,const float *input,float *output) {
    if (!s || !input || !output) return 0;
    unsigned count=s->count,half=count/2;
    Complex *data=s->scratch;
    for (unsigned i=0;i<count;i++) data[i]=(Complex){input[i],0};
    unsigned reverse=0;
    for (unsigned i=1;i<count-1;i++) {
        reverse=next_reversed(reverse,half);
        if (i<reverse) { Complex saved=data[i];data[i]=data[reverse];data[reverse]=saved; }
    }
    for (unsigned size=4;size<=count;size*=2) {
        unsigned quarter=size/4;
        group(data,0,quarter,NULL,NULL,0);
        if (size==count) continue;
        group(data,size,quarter,s->twiddles+half,NULL,1);
        unsigned index=half;
        for (unsigned base=size*2;base<count;base+=size) {
            index=next_reversed(index,half);
            group(data,base,quarter,s->twiddles+index,s->twiddles+index*3,0);
        }
    }
    for (unsigned stride=half;stride;stride>>=2)
        for (unsigned i=half-stride;i<half-(stride>>1);i++) {
            Complex a=data[i],b=data[i+half];
            data[i]=(Complex){(float)((double)a.r+b.r),(float)((double)a.i+b.i)};
            data[i+half]=(Complex){(float)((double)a.r-b.r),(float)((double)a.i-b.i)};
        }
    float scale=1.0f/count;
    for (unsigned i=0;i<half;i++) { output[i*2]=scale*data[i].r;output[i*2+1]=scale*data[i].i; }
    output[1]=scale*data[half].r;
    return 1;
}
