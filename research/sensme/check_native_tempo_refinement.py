"""Compare native mono tempo refinement to verified full-process observations."""
import argparse
import array
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from check_native_spectral_stats import local_path
from synthetic_tempo_input import make as synthetic_input


class Estimate(C.Structure):
    _fields_=[('selected_candidate',C.c_int32),('adjusted_candidate',C.c_int32)]+[
        (name,C.c_double) for name in ['raw_period','initial_period','initial_phase','refined_period',
                                     'first_phase','final_period','final_phase']]+[
        (name,C.c_float) for name in ['predicted_log_bpm','bpm','period_frames','phase_frames']]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--candidates-report',type=Path)
    p.add_argument('--refinement-report',type=Path,required=True);p.add_argument('--onset-prefix',type=Path)
    p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    report=json.loads(args.refinement_report.read_text())
    stages={}
    for entry in report['observations']:stages.setdefault(entry['stage'],entry)
    frames=stages['refined_period']['frames']
    if 'syntheticInput' in report:
        spec=report['syntheticInput'];candidates,onsets,stats=synthetic_input(spec['case'],frames,spec['segments'])
        if hashlib.sha256(onsets.tobytes()).hexdigest()!=spec['onsetsSHA256'] or hashlib.sha256(stats.tobytes()).hexdigest()!=spec['statsSHA256']:
            raise ValueError('Synthetic input digest differs')
    else:
        if not args.candidates_report or not args.onset_prefix:p.error('Real validation requires --candidates-report and --onset-prefix')
        candidates_report=json.loads(args.candidates_report.read_text());segments=len(candidates_report['segments'])//3
        candidates=[candidates_report['segments'][band*segments+segment]['candidate'] for segment in range(segments) for band in range(3)]
        onsets=array.array('f')
        for band in range(3):
            raw=Path(str(args.onset_prefix)+f'.onsets-{band}.bin').read_bytes()
            onsets.frombytes(raw.ljust(frames*4,b'\0'))
        raw=local_path(candidates_report['energyBlocksPath']).read_bytes()
        if hashlib.sha256(raw).hexdigest()!=candidates_report['energySHA256']:raise ValueError('Energy digest differs')
        words=array.array('H');words.frombytes(raw)
    source=(C.c_int32*len(candidates))(*candidates)
    lib=C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_spectral_create.argtypes=[C.c_int];lib.negi_sensme_spectral_create.restype=C.c_void_p
    lib.negi_sensme_spectral_destroy.argtypes=[C.c_void_p]
    lib.negi_sensme_spectral_block.argtypes=[C.c_void_p,C.POINTER(C.c_uint16),C.POINTER(C.c_float),C.POINTER(C.c_float),C.POINTER(C.c_float)]
    lib.negi_sensme_tempo_refine.argtypes=[C.POINTER(C.c_int32),C.c_size_t,C.POINTER(C.c_float),C.c_size_t,C.POINTER(C.c_float),C.POINTER(Estimate),C.POINTER(C.c_float)]
    lib.negi_sensme_tempo_vote.argtypes=[C.POINTER(C.c_int32),C.c_size_t,C.POINTER(C.c_int32)]
    if 'syntheticInput' not in report:
        state=lib.negi_sensme_spectral_create(1)
        if not state:raise RuntimeError('Statistics allocation failed')
        stats=array.array('f')
        try:
            for block in range(frames//128):
                means=(C.c_float*16)();deviations=(C.c_float*16)();energy=(C.c_uint16*(128*72)).from_buffer(words,block*128*144)
                if not lib.negi_sensme_spectral_block(state,energy,means,deviations,None):raise RuntimeError('Statistics block failed')
                stats.extend(means);stats.extend(deviations)
        finally:lib.negi_sensme_spectral_destroy(state)
    output=Estimate();weighted=(C.c_float*frames)()
    if not lib.negi_sensme_tempo_refine(source,len(candidates),(C.c_float*len(onsets)).from_buffer(onsets),frames,
                                      (C.c_float*len(stats)).from_buffer(stats),C.byref(output),weighted):
        raise RuntimeError('Native tempo refinement failed')
    expected_weighted=local_path(stages['refined_period']['weightedOnsetsPath']).read_bytes()
    if hashlib.sha256(expected_weighted).hexdigest()!=stages['refined_period']['weightedOnsetsSHA256']:raise ValueError('Weighted curve digest differs')
    mismatches=sum(bytes(weighted)[i:i+4]!=expected_weighted[i:i+4] for i in range(0,len(expected_weighted),4))
    def frame(stage):return local_path(stages[stage]['framePath']).read_bytes()
    def state(stage):return local_path(stages[stage]['statePath']).read_bytes()
    expected={
        'adjusted_candidate':stages['refined_period']['candidate'],
        'initial_phase':struct.unpack_from('<d',frame('refined_period'),0x54)[0],
        'refined_period':struct.unpack_from('<d',frame('refined_period'),0x4c)[0],
        'first_phase':struct.unpack_from('<d',frame('first_phase'),0x54)[0],
        'final_period':struct.unpack_from('<d',frame('final_phase'),0x4c)[0],
        'final_phase':struct.unpack_from('<d',frame('final_phase'),0x54)[0],
        'predicted_log_bpm':struct.unpack_from('<f',state('final_phase'),0x46c)[0],
        'bpm':struct.unpack_from('<f',state('final_phase'),0x468)[0],
        'period_frames':struct.unpack_from('<f',frame('grid_allocation'),0x30)[0],
        'phase_frames':struct.unpack_from('<f',frame('grid_allocation'),0x1c)[0]}
    if 'vote_period' in stages:
        expected.update(selected_candidate=stages['vote_period']['candidate'],raw_period=struct.unpack_from('<d',frame('vote_period'),0x4c)[0])
    native={name:getattr(output,name) for name,_ in Estimate._fields_}
    differences={}
    for name,value in expected.items():
        kind=dict(Estimate._fields_)[name];fmt='<f' if kind is C.c_float else '<d' if kind is C.c_double else '<i'
        if struct.pack(fmt,native[name])!=struct.pack(fmt,value):differences[name]=dict(native=native[name],reference=value)
    result=dict(exact=not differences and not mismatches,weightedMismatches=mismatches,native=native,reference=expected,differences=differences)
    args.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    return 0 if result['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
