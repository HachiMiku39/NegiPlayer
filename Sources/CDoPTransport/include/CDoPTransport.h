#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <stddef.h>
typedef struct NegiDoP NegiDoP;
NegiDoP *negi_dop_create(uint32_t capacity);
void negi_dop_destroy(NegiDoP *s);
// Producer writes chronological, MSB-first [L0,L1,R0,R1] frames.
uint32_t negi_dop_space(NegiDoP *s);
uint32_t negi_dop_write(NegiDoP *s, const uint8_t *data, uint32_t frames);
void negi_dop_pause(NegiDoP *s, int paused);
void negi_dop_eof(NegiDoP *s);
// Reset marker phase with the IOProc stopped; queued music remains intact.
void negi_dop_reset_phase(NegiDoP *s);
// Call reset only when the IOProc and producer are both stopped.
void negi_dop_reset(NegiDoP *s);
uint64_t negi_dop_played(NegiDoP *s);
uint64_t negi_dop_underruns(NegiDoP *s);
uint64_t negi_dop_callbacks(NegiDoP *s);
int negi_dop_drained(NegiDoP *s);
int negi_dop_fault(NegiDoP *s);
void negi_dop_fail(NegiDoP *s);
void negi_dop_expect(NegiDoP *s, AudioDeviceID device, AudioStreamID stream, double rate);
OSStatus negi_dop_changed(AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses, void *context);
OSStatus negi_dop_io(AudioDeviceID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context);
AudioDeviceIOProc negi_dop_io_callback(void);
AudioObjectPropertyListenerProc negi_dop_listener_callback(void);
// Same render routine used by IOProc, exposed for independent byte-vector tests.
void negi_dop_render(NegiDoP *s, uint8_t *output, uint32_t frames);
