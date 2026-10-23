#include "NegiSensMeCore.h"
#include <stdlib.h>
#include <string.h>

static int snap_downbeat(int target,const int32_t *beats,int count) {
    int selected=target,best=100;
    for (int at=target-8;at<target+8;at++) {
        int distance=abs(at-target);
        if (at>=0 && at<count && beats[at]==1 && distance<=best) { selected=at;best=distance; }
    }
    return selected;
}

int negi_sensme_coarse_sections(const uint16_t *matrix,size_t count,const int32_t *beat_numbers,
                               int32_t *output,size_t *section_count) {
    if (count<2 || count>960 || !beat_numbers || !output || !section_count) return 0;
    for (size_t i=0;i<count;i++) if (beat_numbers[i]<1 || beat_numbers[i]>4) return 0;
    int side=(int)(count/2)-1;
    if (side && !matrix) return 0;
    size_t cells=(size_t)side*side;
    uint16_t *working=cells ? malloc(cells*sizeof(*working)) : NULL;
    uint16_t *runs=cells ? malloc(cells*sizeof(*runs)) : NULL;
    if (cells && (!working || !runs)) { free(working);free(runs);return 0; }
    if (cells) memcpy(working,matrix,cells*sizeof(*working));
    int32_t labels[960];for (size_t i=0;i<count;i++) labels[i]=-1;
    uint32_t threshold_bits=0x3e805401;float threshold_value;memcpy(&threshold_value,&threshold_bits,4);
    const uint16_t threshold=(uint16_t)((double)threshold_value*65535);
    int assigned=0;
    for (;;) {
        if (cells) memset(runs,0,cells*sizeof(*runs));
        for (int diagonal=0;diagonal<side-1;diagonal++) {
            runs[diagonal*side+diagonal]=65535;
            uint16_t length=0;
            for (int row=side-2-diagonal;row>0;row--) {
                int column=row+diagonal;uint16_t value=working[row*side+column];
                if (value<threshold || value<=working[(row-1)*side+column] || value<=working[(row+1)*side+column]) length=0;
                else length++;
                runs[row*side+column]=runs[column*side+row]=length;
            }
        }
        for (size_t i=0;i<cells;i++) runs[i]=runs[i]>=11;
        int best_count=0,best_start=0,best_length=0,run_length=0;
        for (int row=0;row<side;row++) {
            int degree=0;for (int column=0;column<side;column++) degree+=runs[row*side+column];
            run_length=degree ? 1 : run_length+1;
            if (degree>best_count || (degree==best_count && run_length>best_length)) {
                best_start=row-run_length+1;best_count=degree;best_length=run_length;
            }
        }
        if (best_count<2) break;
        if (assigned>=side) { free(working);free(runs);return 0; }
        int offsets[100],offset_count=0;
        for (int column=0;column<side && offset_count<100;column++)
            if (runs[best_start*side+column]) offsets[offset_count++]=column-best_start;
        int start=best_start-1;
        for (;start>0;start--) {
            int matches=0;
            for (int i=0;i<offset_count;i++) {
                int column=start+offsets[i];if (column<0) break;
                if (working[start*side+column]>=threshold) matches++;
            }
            if (matches<best_count) break;
        }
        start++;
        int end=best_start+1;
        for (;end<side;end++) {
            int matches=0;
            for (int i=0;i<offset_count;i++) {
                int column=end+offsets[i];if (column>=side) break;
                if (working[end*side+column]>=threshold) matches++;
            }
            if (matches<best_count) break;
        }
        int first=snap_downbeat(start*2+5,beat_numbers,(int)count),last=end*2+5;
        if (last-first<23) last=first+23;
        last=snap_downbeat(last,beat_numbers,(int)count);
        for (int at=first;at<last;at++) for (int i=0;i<offset_count;i++) {
            int beat=at+offsets[i]*2;
            if (beat>=0 && beat<(int)count && labels[beat]==-1) labels[beat]=assigned;
        }
        assigned++;
        for (int i=0;i<offset_count;i++) for (int at=start;at<end;at++) {
            int row=at+offsets[i];
            if (row>=0 && row<side) for (int column=0;column<side;column++) {
                working[row*side+column]=0;working[column*side+row]=0;
            }
        }
    }
    free(working);free(runs);
    int previous=-1,length=0,combined=0;
    for (int at=(int)count-1;at>=0;at--) {
        int label=labels[at];
        if (label!=previous) {
            if (length<23) for (int i=at+1;i<at+1+combined && i<(int)count;i++) labels[i]=label;
            else combined=0;
            length=0;previous=label;
        }
        length++;combined++;
    }
    int32_t mapping[960]={0};size_t unique=0;
    for (size_t i=0;i<count;i++) if (labels[i]>=0 && !mapping[labels[i]]) mapping[labels[i]]=(int32_t)++unique;
    for (size_t i=0;i<count;i++) if (labels[i]>=0) labels[i]=mapping[labels[i]]-1;
    memcpy(output,labels,count*sizeof(*output));*section_count=unique;return 1;
}
