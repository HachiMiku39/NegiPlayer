#include "NegiSensMeCore.h"
#include "NegiSensMeResultParameters.h"
#include <math.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

enum { WORDS=189 };
#define AT(offset) values[((offset)-0x10)/4]

static int put(uint32_t *values,size_t offset,double value) {
    // The original conversion returns int64, and the collector stores its low
    // word. Avoid undefined C signed narrowing/overflow for large statistics.
    if (!isfinite(value) || value>=0x1p63 || value< -0x1p63) return 0;
    AT(offset)=(uint32_t)(uint64_t)(int64_t)value;return 1;
}

static double normalize(double input,size_t index) {
    double denominator=result_deviations[index]*6;
    double score=input*(100/denominator);
    double center=result_centers[index]*100/denominator;
    return score+(50-center);
}

static float deviation(const float *values,size_t count) {
    double sum=0,squares=0;
    for (size_t i=0;i<count;i++) sum+=values[i];
    float mean=(float)(sum/count);
    for (size_t i=0;i<count;i++) {
        double delta=(double)values[i]-mean;squares+=delta*delta;
    }
    return (float)sqrt(squares/(count-1));
}

static int timestamp(uint32_t *values,size_t *count,int32_t *last,float time) {
    int32_t current=(int32_t)time;
    if (*last==current) return 1;
    if (*count>=32) return 0;
    AT(0x14+4*(*count))=(uint32_t)current;*last=current;(*count)++;return 1;
}

int negi_sensme_result_features(const NegiSensMeBeat *beats,const NegiSensMeSectionKey *keys,
    const int32_t *sections,size_t count,const float *summaries,float bpm,
    float log_bpm,float spectrum_spread,int32_t chorus_type,size_t chorus_beat,
    NegiSensMeResultFeatures *output) {
    if (!beats || !keys || !sections || !summaries || !output || !count || count>960 ||
        chorus_beat>count || chorus_type< -1 || chorus_type>99 || !isfinite(bpm) ||
        !isfinite(log_bpm) || !isfinite(spectrum_spread)) return 0;
    for (size_t i=0;i<128;i++) if (!isfinite(summaries[i])) return 0;
    for (int i=4;i<8;i++) if (summaries[64+i]<0) return 0;
    for (size_t i=0;i<count;i++) {
        if (!isfinite(beats[i].milliseconds) || beats[i].milliseconds<0 || beats[i].milliseconds>300000 ||
            (i && beats[i].milliseconds<=beats[i-1].milliseconds) || beats[i].tonal_class<0 ||
            beats[i].tonal_class>23 || keys[i].root<0 || keys[i].root>11 || sections[i]< -1 || sections[i]>99) return 0;
        for (int j=0;j<24;j++) if (!isfinite(beats[i].probabilities[j]) || beats[i].probabilities[j]<0 || beats[i].probabilities[j]>1) return 0;
        for (int j=0;j<12;j++) if (!isfinite(keys[i].probabilities[j]) || keys[i].probabilities[j]<0 || keys[i].probabilities[j]>1) return 0;
    }
    uint32_t values[WORDS]={0};
    if (chorus_beat<count) AT(0x10)=(uint32_t)(int32_t)beats[chorus_beat].milliseconds;
    size_t timestamps=0,next=0;int previous=-2;int32_t last=-1;
    for (size_t k=count;k && timestamps<32;) {
        size_t i=--k;
        if (i==chorus_beat && (int32_t)beats[next].milliseconds!=last) {
            if (!timestamp(values,&timestamps,&last,beats[i].milliseconds)) return 0;
        }
        if (i!=count-1 && (sections[i]!=previous || !i) && previous==chorus_type) {
            if (!timestamp(values,&timestamps,&last,beats[next].milliseconds)) return 0;
        }
        previous=sections[i];next=i;
    }
    AT(0x94)=(uint32_t)timestamps;
    int counts[16]={0},major=0,old_relative=-1,old_mode=-1;
    unsigned char transitions[576]={0};
    for (size_t i=0;i<count;i++) {
        int cls=beats[i].tonal_class,mode=cls/12,relative=(cls%12-keys[i].root+12)%12;
        int current=relative+mode*12,old=old_relative+old_mode*12;
        AT(0xf0+4*cls)++;
        // First predecessor mode is -1: its count lands in the final two
        // absolute-histogram words. This is observed reference behavior.
        AT(4*(0x54+2*old_mode+mode))++;
        AT(0x160+4*current)++;
        major+=mode==0;
        counts[0]+=current==0;counts[1]+=current==5;counts[2]+=current==7;counts[3]+=current==21;
        counts[4]+=current==2 || current==14;counts[5]+=current==4 || current==16;
        if (old>=0) {
            counts[6]+=old==0 && current==5;counts[7]+=old==0 && current==7;
            counts[8]+=old==5 && current==7;counts[9]+=old==5 && current==0;
            counts[10]+=old==7 && current==0;
            counts[11]+=old==21 && (current==2 || current==14);
            counts[12]+=old==21 && (current==4 || current==16);
            counts[13]+=(old==2 || old==14) && (current==4 || current==16);
            counts[14]+=(old==2 || old==14) && current==21;
            counts[15]+=(old==4 || old==16) && current==21;
        }
        if ((relative!=old_relative || mode!=old_mode) && old_relative>=0 && old_mode>=0)
            transitions[relative+12*(old_relative+12*(mode+2*old_mode))]=1;
        old_relative=relative;old_mode=mode;
    }
    double stored_bpm=bpm;memcpy(values+(0x2e0-0x10)/4,&stored_bpm,8);
    if (!put(values,0x2f4,log_bpm*p3df00*p3def8-p3def0) ||
        !put(values,0x2f8,spectrum_spread*p3dee8*p3dee0-p3ded8) ||
        !put(values,0xac,(double)major/count*p3dee8*p3ded0-p3dec8)) return 0;
    for (int i=0;i<16;i++) if (!put(values,(i<6 ? 0xb0+4*i : 0xc8+4*(i-6)),
        normalize((double)counts[i]/count*p3dee8,(size_t)i+2))) return 0;
    int distinct=0;for (int i=0;i<576;i++) distinct+=transitions[i]!=0;
    if (!put(values,0x1c0,distinct*10000*p3deb0+p3dea8)) return 0;
    for (size_t offset=0xf0;offset<0x1c0;offset+=4) AT(offset)=AT(offset)*1000/(uint32_t)count;
    float tonal=0,root=0;
    for (size_t i=0;i<count;i++) {
        tonal=(float)((double)tonal+deviation(beats[i].probabilities,24));
        root=(float)((double)root+deviation(keys[i].probabilities,12));
    }
    tonal=(float)((double)tonal/count);root=(float)((double)root/count);
    if (!put(values,0x2e8,(1-(double)tonal)*p3dee8*p3dea0-p3de98) ||
        !put(values,0x1dc,(1-(double)root)*p3dee8*p3de90-p3de88)) return 0;
    const float *u=summaries+64;
    if (!put(values,0x1c4,u[8]*p3de80*p3de78-p3de70) ||
        !put(values,0xa0,u[9]*p3dee8*p3de68+p3de60) ||
        !put(values,0x1d0,u[11]*p3dee8*p3de58-p3de50) ||
        !put(values,0x1d4,(1-(double)u[13])*p3dee8*p3de48-p3de40) ||
        !put(values,0x1d8,((double)u[12]+u[10])*p3dee8*p3de38+p3de30)) return 0;
    double total=0,primary=0;
    for (int i=0;i<2;i++) {
        double a=sqrt((double)u[4+i]),b=sqrt((double)u[6+i]);
        primary+=a;total+=b;total+=a;
    }
    if (u[0]>0 && !put(values,0x2f0,(primary-total)/u[0]*p3dee8*p3de28+p3de20)) return 0;
    if (!put(values,0x9c,u[14]*p3dee8*p3de18-p3de10) ||
        !put(values,0x98,(1-(double)u[3])*p3dee8*p3de08-p3de00) ||
        !put(values,0x1c8,(1-(double)u[15])*p3dee8*p3ddf8-p3ddf0) ||
        !put(values,0x1cc,u[16]*p3dee8*p3dde8+p3dde0) ||
        !put(values,0xa4,u[1]*p3dee8*p3ddd8+p3ddd0) ||
        !put(values,0xa8,u[2]*p3dee8*p3ddc8+p3ddc0)) return 0;
    for (int i=0;i<64;i++) if (!put(values,0x1e0+4*i,normalize((double)summaries[i]*100000000,(size_t)i+33))) return 0;
    memcpy(output->words,values,sizeof(values));return 1;
}

#undef AT
