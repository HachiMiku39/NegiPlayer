#include "NegiSensMeCore.h"
#include <math.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

static float as_float(uint32_t bits) { float value;memcpy(&value,&bits,4);return value; }

static float key_score(const float *a,const float *b) {
    // Evaluation order and the one intermediate float store are significant.
    double c=(double)b[3]+b[2];
    double t=(double)b[2]+a[8];t+=b[3];c+=t;
    t=(double)a[10]+a[5];c+=t;c+=a[5];c+=b[10];
    float stored=(float)((double)b[4]+a[7]);
    double u=(double)b[0]+a[4],v=(double)stored+u;v+=a[4];
    u+=a[4];u+=a[9];u+=b[11];
    double w=(double)b[7]*as_float(0xbf7874ec);
    w+=a[7];w+=b[8];w+=b[4];w+=u;w+=a[4];w+=a[7];
    w+=v;w+=a[4];w+=a[4];
    double result=w*c;result*=((double)b[9]+a[0]);
    result*=as_float(0xbf600efd);result*=as_float(0xb4ee0314);
    return (float)(result+as_float(0x42300f92));
}

static float key_likelihood(float input) {
    double da=(double)input-as_float(0x42bd2e21),db=(double)input-as_float(0x42379ea5);
    double sa=as_float(0x415ff02e),sb=as_float(0x4098710b);
    double a=exp(-(da*da)/(2*sa*sa)),b=exp(-(db*db)/(2*sb*sb));
    return a+b>0 ? (float)(a/(a+b)) : input;
}

int negi_sensme_section_keys(const int32_t *classes,const int32_t *sections,size_t count,
                            NegiSensMeSectionKey *output) {
    if (count>960 || (count && (!classes || !sections || !output))) return 0;
    for (size_t i=0;i<count;i++) if (classes[i]<0 || classes[i]>23) return 0;
    for (size_t start=0;start<count;) {
        size_t end=start+1;
        while (end<count && sections[end]==sections[start]) end++;
        float histogram[24]={0};
        for (size_t i=start;i<end;i++) histogram[classes[i]]+=1;
        for (int tone=0;tone<24;tone++) histogram[tone]=(float)((double)histogram[tone]*1000/(double)(end-start));
        NegiSensMeSectionKey key={0};
        for (int root=0;root<12;root++) {
            float major[12],minor[12];
            for (int tone=0;tone<12;tone++) {
                major[tone]=histogram[(root+tone)%12];minor[tone]=histogram[12+(root+tone)%12];
            }
            key.probabilities[root]=key_likelihood(key_score(major,minor));
            if (key.probabilities[key.root]<key.probabilities[root]) key.root=root;
        }
        for (size_t i=start;i<end;i++) output[i]=key;
        start=end;
    }
    return 1;
}
