#include "CDoPTransport.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

struct NegiDoP {
    uint8_t *bytes;
    uint32_t capacity;
    _Atomic uint64_t read, write, played, underruns, callbacks;
    _Atomic int paused, eof, fault;
    uint8_t marker;
    AudioDeviceID device;
    AudioStreamID stream;
    double rate;
};
NegiDoP *negi_dop_create(uint32_t capacity) {
    if (!capacity || capacity > 1048576) return NULL;
    NegiDoP *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->bytes = malloc((size_t)capacity * 4);
    if (!s->bytes) { free(s); return NULL; }
    s->capacity = capacity; s->marker = 5; atomic_store(&s->paused, 1);
    return s;
}
void negi_dop_destroy(NegiDoP *s) { if (s) { free(s->bytes); free(s); } }
uint32_t negi_dop_space(NegiDoP *s) {
    uint64_t w = atomic_load_explicit(&s->write, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&s->read, memory_order_acquire);
    return s->capacity - (uint32_t)(w-r);
}
uint32_t negi_dop_write(NegiDoP *s, const uint8_t *data, uint32_t frames) {
    uint32_t n = negi_dop_space(s); if (n > frames) n = frames;
    uint64_t w = atomic_load_explicit(&s->write, memory_order_relaxed);
    for (uint32_t i=0; i<n; ++i) memcpy(s->bytes + ((w+i)%s->capacity)*4, data+i*4, 4);
    atomic_store_explicit(&s->write, w+n, memory_order_release); return n;
}
void negi_dop_pause(NegiDoP *s, int paused) { atomic_store(&s->paused, paused); }
void negi_dop_eof(NegiDoP *s) { atomic_store_explicit(&s->eof, 1, memory_order_release); }
// Only call after AudioDeviceStop, while the callback is no longer running.
void negi_dop_reset_phase(NegiDoP *s) { s->marker=5; }
void negi_dop_reset(NegiDoP *s) {
    atomic_store(&s->read,0); atomic_store(&s->write,0); atomic_store(&s->played,0);
    atomic_store(&s->eof,0); s->marker=5;
}
uint64_t negi_dop_played(NegiDoP *s) { return atomic_load(&s->played); }
uint64_t negi_dop_underruns(NegiDoP *s) { return atomic_load(&s->underruns); }
uint64_t negi_dop_callbacks(NegiDoP *s) { return atomic_load(&s->callbacks); }
int negi_dop_drained(NegiDoP *s) { return atomic_load(&s->eof) && atomic_load(&s->read)==atomic_load(&s->write); }
int negi_dop_fault(NegiDoP *s) { return atomic_load(&s->fault); }
void negi_dop_fail(NegiDoP *s) { atomic_store(&s->fault,1); }
void negi_dop_render(NegiDoP *s, uint8_t *output, uint32_t frames) {
    uint64_t r = atomic_load_explicit(&s->read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&s->write, memory_order_acquire);
    uint64_t before = r;
    int paused = atomic_load(&s->paused);
    for (uint32_t i=0; i<frames; ++i) {
        const uint8_t silence[4] = {0x69,0x69,0x69,0x69};
        const uint8_t *p = silence;
        if (!paused && r<w) { p=s->bytes+(r%s->capacity)*4; ++r; }
        else if (!paused && !atomic_load(&s->eof)) atomic_fetch_add(&s->underruns,1);
        // Oldest DSD bit occupies bit 15. USB LPCM words are little-endian.
        output[0]=p[1]; output[1]=p[0]; output[2]=s->marker;
        output[3]=p[3]; output[4]=p[2]; output[5]=s->marker;
        output+=6; s->marker = s->marker==5 ? 0xFA : 5;
    }
    atomic_store_explicit(&s->read, r, memory_order_release);
    atomic_fetch_add(&s->played, r-before); atomic_fetch_add(&s->callbacks,1);
}
void negi_dop_expect(NegiDoP *s, AudioDeviceID device, AudioStreamID stream, double rate) { s->device=device; s->stream=stream; s->rate=rate; }
static int exact_format(AudioStreamBasicDescription f, double rate) {
    const UInt32 mask = kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsAlignedHigh;
    const UInt32 required=kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonMixable;
    return f.mFormatID==kAudioFormatLinearPCM && fabs(f.mSampleRate-rate)<0.1 && f.mChannelsPerFrame==2 && f.mBitsPerChannel==24 && f.mBytesPerFrame==6 && f.mBytesPerPacket==6 && f.mFramesPerPacket==1 && !(f.mFormatFlags & mask) && (f.mFormatFlags & required)==required;
}
OSStatus negi_dop_changed(AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses, void *context) {
    NegiDoP *s=context;
    AudioObjectPropertyAddress a={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    double rate=0; UInt32 n=sizeof(rate);
    int fault=0;
    if (AudioObjectGetPropertyData(s->device,&a,0,NULL,&n,&rate)!=noErr || fabs(rate-s->rate)>=0.1) fault|=1;
    a.mSelector=kAudioDevicePropertyHogMode; pid_t owner=-1; n=sizeof(owner);
    if (AudioObjectGetPropertyData(s->device,&a,0,NULL,&n,&owner)!=noErr || owner!=getpid()) fault|=2;
    UInt32 selectors[2]={kAudioStreamPropertyPhysicalFormat,kAudioStreamPropertyVirtualFormat};
    for (int i=0; i<2; ++i) {
        a.mSelector=selectors[i]; AudioStreamBasicDescription f={0}; n=sizeof(f);
        if (AudioObjectGetPropertyData(s->stream,&a,0,NULL,&n,&f)!=noErr || !exact_format(f,s->rate)) fault|=(4<<i);
    }
    if (fault) atomic_fetch_or(&s->fault,fault);
    return noErr;
}
OSStatus negi_dop_io(AudioDeviceID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    NegiDoP *s=context;
    if (atomic_load(&s->fault) || output->mNumberBuffers!=1 || output->mBuffers[0].mNumberChannels!=2 || !output->mBuffers[0].mData || output->mBuffers[0].mDataByteSize%6) {
        atomic_fetch_or(&s->fault,16);
        for (UInt32 i=0; i<output->mNumberBuffers; ++i) if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData,0,output->mBuffers[i].mDataByteSize);
        return noErr;
    }
    negi_dop_render(s,output->mBuffers[0].mData,output->mBuffers[0].mDataByteSize/6); return noErr;
}
AudioDeviceIOProc negi_dop_io_callback(void) { return negi_dop_io; }
AudioObjectPropertyListenerProc negi_dop_listener_callback(void) { return negi_dop_changed; }
