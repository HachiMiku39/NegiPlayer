#include "NegiSensMeCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma STDC FP_CONTRACT OFF

enum { MAX_BEATS=960, MAX_EVENTS=5*MAX_BEATS+10, MAX_BYTES=200000 };
typedef struct { uint16_t position; uint32_t code,time; } Event;
typedef struct { uint32_t start,end; uint16_t bars,key; } Region;
typedef struct { uint32_t time,code; } Marker;
typedef struct {
    Event events[MAX_EVENTS]; Region regions[MAX_BEATS]; Marker markers[MAX_BEATS];
    size_t events_count,regions_count,markers_count;
    uint32_t categories[256];
} Track;
typedef struct { uint8_t *data; size_t at; } Writer;

static int32_t signed_word(uint32_t word) { int32_t value;memcpy(&value,&word,4);return value; }
static uint32_t word(const NegiSensMeResultFeatures *f,size_t offset) { return f->words[(offset-0x10)/4]; }
static double bpm(const NegiSensMeResultFeatures *f) { double value;memcpy(&value,f->words+(0x2e0-0x10)/4,8);return value; }
static uint32_t truncate_word(double value) {
    if (!isfinite(value) || value>=0x1p63 || value< -0x1p63) return 0;
    return (uint32_t)(uint64_t)(int64_t)value;
}
static uint8_t clipped(uint32_t value) {
    int32_t v=signed_word(value);return v<0 ? 0 : v>254 ? 254 : (uint8_t)v;
}
static void byte(Writer *w,uint8_t v) { if(w->data && w->at<MAX_BYTES)w->data[w->at]=v;w->at++; }
static void be16(Writer *w,uint16_t v) { byte(w,(uint8_t)(v>>8));byte(w,(uint8_t)v); }
static void be32(Writer *w,uint32_t v) { be16(w,(uint16_t)(v>>16));be16(w,(uint16_t)v); }
static void f32(Writer *w,float v) { uint32_t bits;memcpy(&bits,&v,4);be32(w,bits); }
static void zeros(Writer *w,size_t n) { while(n--)byte(w,0); }
static void chunk(Writer *w,const char *name,uint32_t size) {
    for(int i=0;i<4;i++)byte(w,(uint8_t)name[i]);
    const uint8_t stamp[12]={'S','T','A','E','M','M','L','W',1,0,0x80,0};
    for(int i=0;i<12;i++)byte(w,stamp[i]);be32(w,size);
}
static uint32_t sample_time(float ms,uint32_t offset) {
    // Original conversion multiplies by the stored float reciprocal of 1000.
    return truncate_word((44100.0*(double)0x1.0624dep-10)*(double)ms)+offset;
}
static uint16_t position(const NegiSensMeBeat *beat,int32_t first_bar) {
    return (uint16_t)(((uint32_t)beat->bar-(uint32_t)first_bar+1)*16+((uint32_t)beat->beat&15));
}
static uint32_t key_code(int32_t root) { return root>=0 && root<12 ? (uint32_t)root+1+128 : 127; }
static uint32_t chord_code(int32_t cls,int32_t root) {
    static const uint8_t degree[12]={1,1,2,3,3,4,4,5,5,6,7,7};
    static const uint8_t alteration[12]={0,2,0,1,0,0,2,0,2,0,1,0};
    unsigned relative=(unsigned)(cls%12-root+12)%12;
    uint32_t quality=cls/12==0 ? 0x24 : cls/12==1 ? 0x22 : 0;
    return (((quality|0x480000)*8+degree[relative])*4)|alteration[relative];
}
static void event(Track *t,uint16_t pos,uint32_t code,uint32_t time) {
    t->events[t->events_count++]=(Event){pos,code,time};t->categories[code>>24]++;
}
static void region(Track *t,uint32_t start,uint16_t bars,int32_t root) {
    t->regions[t->regions_count++]=(Region){start,(uint32_t)(t->events_count-1)*10,bars,(uint16_t)key_code(root)};
}
static void markers(Track *t,const NegiSensMeEncodedInput *input) {
    int previous=-2;size_t following=0,encountered=0;
    for(size_t n=input->count;n;) {
        size_t i=--n;
        if(i!=input->count-1 && (input->sections[i]!=previous || !i)) {
            uint32_t time=sample_time(input->beats[following].milliseconds,0),code=0;
            if(previous==input->chorus_type || following==input->chorus_beat)code=8;
            else if(previous==-1) {
                if(!i){code=1;time=0;}else code=encountered ? 10 : 31;
            } else if(!i){code=1;time=0;}
            else if(previous>=0 && previous<6)code=(uint32_t)previous+2;
            if(code)t->markers[t->markers_count++]=(Marker){time,code};
            encountered++;
        }
        previous=input->sections[i];following=i;
    }
    // The original inserts each reverse-traversed marker at the list head.
    for(size_t a=0,b=t->markers_count;a<b && a<--b;a++) {
        Marker temp=t->markers[a];t->markers[a]=t->markers[b];t->markers[b]=temp;
    }
}
static uint32_t marker_code(const Marker *m,int bar_start) {
    return (((((uint32_t)(bar_start!=0)|0x20)<<16)|(m->code&31))*8)*16;
}
static void build_track(Track *t,const NegiSensMeEncodedInput *input) {
    const NegiSensMeBeat *beats=input->beats;markers(t,input);
    size_t marker_index=0;int32_t first_bar=beats[0].bar,last_bar=first_bar,root=input->keys[0].root,pitch=beats[0].tonal_class%12;
    uint16_t bars=1,pos=position(beats,first_bar);uint32_t time=sample_time(beats[0].milliseconds,input->sample_offset),start=0;
    int bar_changed=1;
    event(t,pos,0x2f800001,time);event(t,pos,0x2f800010,time);
    event(t,pos,0x2f800002|((key_code(root)&63)<<7),time);
    event(t,pos,0x2f800003|((truncate_word((float)bpm(input->features))&65535)<<7),time);
    event(t,pos,0x2f800004,time);
    // Reference events store wrapping 32-bit sample times but order markers
    // with signed comparisons, including offsets crossing the sign boundary.
    if(marker_index<t->markers_count && signed_word(t->markers[marker_index].time+input->sample_offset)<=signed_word(time)) {
        event(t,pos,marker_code(&t->markers[marker_index],1),time);marker_index++;
    }
    event(t,pos,chord_code(beats[0].tonal_class,root),time);
    for(size_t i=0;i<input->count;i++) {
        time=sample_time(beats[i].milliseconds,input->sample_offset);pos=position(beats+i,first_bar);
        bar_changed=last_bar!=beats[i].bar;
        if(bar_changed){bars++;last_bar=beats[i].bar;}
        if(root!=input->keys[i].root) {
            uint32_t control=((uint32_t)bar_changed|0x5e)<<23;
            event(t,pos,control|((uint32_t)(t->regions_count+1)<<7)|1,time);
            region(t,start,bars,root);start=(uint32_t)(t->events_count-1)*10;bars=1;root=input->keys[i].root;
            event(t,pos,control|((key_code(root)&63)<<7)|2,time);
        }
        if(pitch!=beats[i].tonal_class%12) {
            event(t,pos,chord_code(beats[i].tonal_class,root),time);pitch=beats[i].tonal_class%12;
        }
        event(t,pos,((uint32_t)bar_changed<<21)|0x010000ff,time);
        if(marker_index<t->markers_count && time==t->markers[marker_index].time+input->sample_offset) {
            event(t,pos,marker_code(&t->markers[marker_index],bar_changed),time);
        }
        if(marker_index<t->markers_count && signed_word(t->markers[marker_index].time+input->sample_offset)<=signed_word(time))marker_index++;
    }
    uint32_t control=((uint32_t)bar_changed|0x5e)<<23;
    event(t,pos,control|0x11,time);event(t,pos,control|0x7fff81,time);region(t,start,bars,root);
}
static void stmm(Writer *w,const Track *t,const NegiSensMeEncodedInput *input) {
    unsigned categories=0;for(int i=0;i<256;i++)categories+=t->categories[i]!=0;
    uint32_t regions_size=(uint32_t)t->regions_count*58+6;
    uint32_t track_size=40+categories*4+(uint32_t)t->events_count*10;
    chunk(w,"STMM",regions_size+track_size);
    be32(w,regions_size-4);be16(w,(uint16_t)t->regions_count);
    for(size_t i=0;i<t->regions_count;i++) {
        const Region *r=t->regions+i;be16(w,(uint16_t)i);be32(w,r->start);be32(w,r->end);
        for(int j=0;j<4;j++)be32(w,UINT32_MAX);
        f32(w,(float)bpm(input->features));byte(w,4);byte(w,4);be16(w,r->bars);be16(w,r->key);zeros(w,22);
    }
    be32(w,track_size-4);be32(w,28+categories*4);be32(w,44100);
    be32(w,t->events[t->events_count-1].time);be32(w,0);be32(w,t->events[t->events_count-1].time);
    byte(w,2);byte(w,16);be16(w,(uint16_t)categories);be32(w,UINT32_MAX);be32(w,(uint32_t)t->events_count);
    for(unsigned i=0;i<256;i++)if(t->categories[i])be32(w,(i<<24)|(t->categories[i]&0xffffff));
    be32(w,(uint32_t)t->events_count*10);
    for(size_t i=0;i<t->events_count;i++) {
        be16(w,t->events[i].position);be32(w,t->events[i].code);be32(w,t->events[i].time);
    }
}

size_t negi_sensme_encode_smfmf(const NegiSensMeEncodedInput *input,uint8_t *output,size_t capacity) {
    if(!input || !input->features || input->count>MAX_BEATS || !isfinite(input->volume) || !isfinite(bpm(input->features)) ||
        input->chorus_type< -1 || input->chorus_type>99 || input->chorus_beat>input->count ||
        word(input->features,0x94)>32 || (input->count && (!input->beats || !input->keys || !input->sections)))return 0;
    for(size_t i=0;i<input->count;i++) {
        const NegiSensMeBeat *b=input->beats+i;
        if(!isfinite(b->milliseconds) || b->milliseconds<0 || b->milliseconds>300000 ||
            (i && b->milliseconds<=input->beats[i-1].milliseconds) || b->bar<0 || b->bar>65535 ||
            b->beat<1 || b->beat>4 || b->tonal_class<0 || b->tonal_class>23 ||
            input->keys[i].root<0 || input->keys[i].root>11 || input->sections[i]< -1 || input->sections[i]>99)return 0;
    }
    Track *track=input->count ? calloc(1,sizeof(*track)) : NULL;
    if(input->count && !track)return 0;
    uint8_t *temporary=output ? malloc(MAX_BYTES) : NULL;
    if(output && !temporary){free(track);return 0;}
    Writer w={temporary,0};const NegiSensMeResultFeatures *f=input->features;
    int long_track=signed_word(input->processed_frames)>=0xeda;
    if(long_track){chunk(&w,"GBPM",4);float value=(float)bpm(f);f32(&w,value<0 ? 0 : value);}
    chunk(&w,"STBF",36);
    static const unsigned offsets[34]={0x2f4,0x2f8,0xac,0xb0,0xb4,0xb8,0xbc,0xc0,0xc4,0xc8,0xcc,0xd0,0xd4,0xd8,0xdc,0xe0,0xe4,0xe8,0xec,0x1c0,0x2e8,0x1dc,0x1c4,0xa0,0x2f0,0x9c,0,0x1c8,0x1cc,0x1d0,0x1d4,0x1d8,0xa4,0xa8};
    byte(&w,long_track ? clipped(truncate_word(input->volume)) : 255);
    byte(&w,long_track ? clipped(truncate_word(bpm(f))) : 255);
    for(size_t i=0;i<34;i++)byte(&w,!long_track || !offsets[i] ? 255 : clipped(word(f,offsets[i])));
    uint32_t count=word(f,0x94);
    if(count) {
        chunk(&w,"STSA",4+4*count);
        uint32_t offset=truncate_word((double)input->sample_offset/(44100.0*(double)0x1.0624dep-10));
        uint32_t value=word(f,0x10)+offset;be32(&w,signed_word(value)<0 ? 0 : value);
        for(size_t i=count;i;) {value=word(f,0x14+4*--i)+offset;be32(&w,signed_word(value)<0 ? 0 : value);}
    }
    if(long_track) {
        chunk(&w,"STMO",160);
        for(unsigned i=0;i<10;i++) {
            int32_t score;negi_sensme_classification_score(f,65+i,&score);
            for(unsigned variation=0;variation<4;variation++){be16(&w,(uint16_t)(0x100+i));byte(&w,(uint8_t)variation);byte(&w,clipped((uint32_t)score));}
        }
        chunk(&w,"STHF",160);
        for(unsigned i=0;i<40;i++) {
            int32_t score;negi_sensme_classification_score(f,25+i,&score);
            be16(&w,(uint16_t)(0x800+i));byte(&w,clipped((uint32_t)score));byte(&w,0);
        }
    }
    if(input->count){build_track(track,input);stmm(&w,track,input);}
    size_t size=w.at;
    if(size>MAX_BYTES || (output && capacity<size)){free(temporary);free(track);return 0;}
    if(output)memcpy(output,temporary,size);
    free(temporary);free(track);return size;
}
