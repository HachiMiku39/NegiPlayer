"""Check every preliminary beat against private full-analysis observations.

Regenerates tone groups from the actual dispatch energy captures, rather
than trusting an isolated stage's different PCM dispatch partitioning.
"""
import argparse
import array
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from check_native_spectral_stats import local_path


class Beat(C.Structure):
    _fields_=[('milliseconds',C.c_float),('bar',C.c_int32),('beat',C.c_int32),('tonal_class',C.c_int32),
              ('probabilities',C.c_float*24),('reserved_features',C.c_float*14)]


class GridSummary(C.Structure):
    _fields_=[('preliminary_count',C.c_size_t),('count',C.c_size_t),('downbeat_offset',C.c_int32),
              ('downbeat_scores',C.c_float*4),('aligned_phase_frames',C.c_float)]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--candidates-report',type=Path,required=True)
    p.add_argument('--refinement-report',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    args=p.parse_args();tc=json.loads(args.candidates_report.read_text());tr=json.loads(args.refinement_report.read_text())
    if tc['pcmSHA256']!=tr['pcmSHA256'] or tc['unobservedResultSHA256']!=tr['resultSHA256'] or not tr['unobservedVerified']:
        raise ValueError('Full-analysis references differ or observation is not verified')
    stages={x['stage']:x for x in tr['observations']};stage=stages['grid_candidates'];frames=stages['refined_period']['frames']
    raw=local_path(tc['energyBlocksPath']).read_bytes()
    if hashlib.sha256(raw).hexdigest()!=tc['energySHA256']:raise ValueError('Energy digest differs')
    energy=array.array('H');energy.frombytes(raw)
    state=local_path(stages['grid_allocation']['statePath']).read_bytes();stack=local_path(stages['grid_allocation']['framePath']).read_bytes()
    period=struct.unpack_from('<f',stack,0x30)[0];phase=struct.unpack_from('<f',stack,0x1c)[0]
    rate=struct.unpack_from('<f',state,0x114)[0];cap=struct.unpack_from('<i',state,0x120)[0]
    count=min(int((frames-phase)/period)+1,cap)
    reference=local_path(stage['beatsPath']).read_bytes()
    if len(reference)!=count*168:raise ValueError('Beat count differs')
    lib=C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_dynamics_create.restype=C.c_void_p;lib.negi_sensme_dynamics_destroy.argtypes=[C.c_void_p]
    lib.negi_sensme_dynamics_block.argtypes=[C.c_void_p,C.POINTER(C.c_uint16),C.POINTER(C.c_uint16),C.POINTER(C.c_float)]
    lib.negi_sensme_tonal_features.argtypes=[C.POINTER(C.c_uint16),C.POINTER(C.c_uint16),C.c_size_t,C.c_size_t,C.c_size_t,C.POINTER(C.c_float)]
    tone_groups=[(C.c_uint16*(19008*12))() for _ in range(2)]
    accumulator=lib.negi_sensme_dynamics_create()
    if not accumulator:raise RuntimeError('Dynamics allocation failed')
    try:
        for block in range(frames//128):
            source=(C.c_uint16*(128*72)).from_buffer(energy,block*128*144);tones=(C.c_uint16*(3*64*12))();onsets=(C.c_float*384)()
            if not lib.negi_sensme_dynamics_block(accumulator,source,tones,onsets):raise RuntimeError('Dynamics block failed')
            for group in range(2):C.memmove(C.addressof(tone_groups[group])+block*64*24,C.addressof(tones)+group*64*24,64*24)
    finally:lib.negi_sensme_dynamics_destroy(accumulator)
    differences=[]
    for beat in range(count):
        probabilities=(C.c_float*24)();start=int(beat*period+phase)
        selected=lib.negi_sensme_tonal_features(*tone_groups,19008,start,int(period),probabilities)
        timestamp=struct.pack('<f',(beat*period+phase)/rate);base=beat*168
        expected_class=struct.unpack_from('<i',reference,base+12)[0]
        expected_probabilities=reference[base+16:base+112]
        if timestamp!=reference[base:base+4] or selected!=expected_class or bytes(probabilities)!=expected_probabilities:
            actual_words=struct.unpack('<24I',bytes(probabilities));expected_words=struct.unpack('<24I',expected_probabilities)
            differences.append(dict(beat=beat,start=start,selected=[selected,expected_class],
                timestamp=[timestamp.hex(),reference[base:base+4].hex()],
                words={str(i):[hex(a),hex(b)] for i,(a,b) in enumerate(zip(actual_words,expected_words)) if a!=b}))
    result=dict(exact=not differences,beats=count,tonalFloats=count*24,differences=differences)
    if 'grid_final' in stages:
        lib.negi_sensme_beat_grid.argtypes=[C.POINTER(C.c_uint16),C.POINTER(C.c_uint16),C.c_size_t,C.c_float,C.c_float,
                                           C.POINTER(Beat),C.c_size_t,C.POINTER(GridSummary)]
        output=(Beat*960)();summary=GridSummary()
        if not lib.negi_sensme_beat_grid(*tone_groups,frames,period,phase,output,960,C.byref(summary)):raise RuntimeError('Native beat grid failed')
        actual=bytes(output)[:summary.count*168];wanted=local_path(stages['grid_final']['beatsPath']).read_bytes()
        final_differences=[]
        for offset in range(0,min(len(actual),len(wanted)),4):
            if actual[offset:offset+4]!=wanted[offset:offset+4]:
                final_differences.append(dict(beat=offset//168,word=(offset%168)//4,
                                              native=actual[offset:offset+4].hex(),reference=wanted[offset:offset+4].hex()))
        reference_stack=local_path(stage['framePath']).read_bytes()
        scores=struct.pack('<4f',*summary.downbeat_scores);reference_scores=reference_stack[0x304:0x314]
        result['grid']=dict(exact=not final_differences and len(actual)==len(wanted) and scores==reference_scores and summary.downbeat_offset==stage['registers'][1],
                            count=summary.count,referenceCount=len(wanted)//168,preliminaryCount=summary.preliminary_count,
                            selectedDownbeat=[summary.downbeat_offset,stage['registers'][1]],
                            scores=[list(summary.downbeat_scores),list(struct.unpack('<4f',reference_scores))],differences=final_differences)
        result['exact'] &= result['grid']['exact']
    args.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    return 0 if result['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
