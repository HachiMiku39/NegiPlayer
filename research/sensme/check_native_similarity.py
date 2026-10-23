"""Compare native segment descriptors/matrix with private full-process output."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from check_native_spectral_stats import local_path
from synthetic_similarity_input import inputs


def check_synthetic(lib,report):
    cases=[]
    for case in report['cases']:
        if not case['unobservedVerified']:raise ValueError('Synthetic observation was not verified')
        tones,times=inputs(case['kind'],case['count']);count=case['count'];groups=count//2
        source=(C.c_uint16*len(tones)).from_buffer(tones);timestamps=(C.c_float*count)(*times)
        vectors=(C.c_float*(groups*12))();matrix=(C.c_uint16*((groups-1)**2))()
        if not lib.negi_sensme_segment_vectors(source,len(tones)//12,timestamps,count,vectors):raise RuntimeError('Generated descriptors failed')
        if not lib.negi_sensme_similarity_matrix(vectors,groups,matrix):raise RuntimeError('Generated matrix failed')
        expected_vectors=local_path(case['vectorsPath']).read_bytes();expected_matrix=local_path(case['matrixPath']).read_bytes()
        if hashlib.sha256(expected_vectors).hexdigest()!=case['vectorsSHA256'] or hashlib.sha256(expected_matrix).hexdigest()!=case['matrixSHA256']:raise ValueError('Synthetic reference digest differs')
        actual_vectors=bytes(vectors);actual_matrix=bytes(matrix)
        cases.append(dict(kind=case['kind'],beats=count,cells=(groups-1)**2,
                          vectorMismatches=sum(actual_vectors[i:i+4]!=expected_vectors[i:i+4] for i in range(0,len(expected_vectors),4)),
                          matrixMismatches=sum(actual_matrix[i:i+2]!=expected_matrix[i:i+2] for i in range(0,len(expected_matrix),2))))
    return dict(exact=all(not c['vectorMismatches'] and not c['matrixMismatches'] for c in cases),cases=cases)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--synthetic',action='store_true')
    p.add_argument('--candidates-report',type=Path,help='Regenerate compressed tones from actual native dispatch energy');args=p.parse_args()
    report=json.loads(args.report.read_text())
    lib=C.CDLL(str(args.library.resolve()));lib.negi_sensme_segment_vectors.argtypes=[C.POINTER(C.c_uint16),C.c_size_t,C.POINTER(C.c_float),C.c_size_t,C.POINTER(C.c_float)]
    lib.negi_sensme_similarity_matrix.argtypes=[C.POINTER(C.c_float),C.c_size_t,C.POINTER(C.c_uint16)]
    if args.synthetic:
        result=check_synthetic(lib,report);args.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
        return 0 if result['exact'] else 1
    if not report['unobservedVerified']:raise ValueError('Observation was not verified')
    stages={s['stage']:s for s in report['observations']};stage=stages['self_similarity_ready']
    source=local_path(stage['compressedTonesPath']).read_bytes();expected=local_path(stage['matrixPath']).read_bytes()
    if hashlib.sha256(source).hexdigest()!=stage['compressedTonesSHA256'] or hashlib.sha256(expected).hexdigest()!=stage['matrixSHA256']:raise ValueError('Reference digest differs')
    beats=local_path(stages['grid_final']['beatsPath']).read_bytes();count=len(beats)//168;groups=count//2
    state=local_path(stage['statePath']).read_bytes()
    if struct.unpack_from('<i',state,0x47c)[0]!=2 or stage['matrixSide']!=groups-1:raise ValueError('Requires default two-beat grouping')
    tones=(C.c_uint16*(len(source)//2)).from_buffer_copy(source);times=(C.c_float*count)(*[struct.unpack_from('<f',beats,i*168)[0] for i in range(count)])
    native_tones_exact=None
    if args.candidates_report:
        reference=json.loads(args.candidates_report.read_text());energy=local_path(reference['energyBlocksPath']).read_bytes()
        if reference['pcmSHA256']!=report['pcmSHA256'] or hashlib.sha256(energy).hexdigest()!=reference['energySHA256']:raise ValueError('Dispatch energy reference differs')
        lib.negi_sensme_dynamics_create.restype=C.c_void_p;lib.negi_sensme_dynamics_destroy.argtypes=[C.c_void_p]
        lib.negi_sensme_dynamics_block.argtypes=[C.c_void_p,C.POINTER(C.c_uint16),C.POINTER(C.c_uint16),C.POINTER(C.c_float)]
        frames=stages['refined_period']['frames'];regenerated=(C.c_uint16*(19008*12))();accumulator=lib.negi_sensme_dynamics_create()
        if not accumulator:raise RuntimeError('Dynamics allocation failed')
        try:
            for block in range(frames//128):
                data=(C.c_uint16*(128*72)).from_buffer_copy(energy[block*128*144:(block+1)*128*144])
                projected=(C.c_uint16*(3*64*12))();onsets=(C.c_float*384)()
                if not lib.negi_sensme_dynamics_block(accumulator,data,projected,onsets):raise RuntimeError('Native dynamics failed')
                C.memmove(C.addressof(regenerated)+block*64*24,C.addressof(projected)+2*64*24,64*24)
        finally:lib.negi_sensme_dynamics_destroy(accumulator)
        native_tones_exact=bytes(regenerated)==source
        if not native_tones_exact:raise ValueError('Native regenerated tones differ')
        tones=regenerated
    vectors=(C.c_float*(groups*12))();matrix=(C.c_uint16*((groups-1)**2))()
    if not lib.negi_sensme_segment_vectors(tones,len(source)//24,times,count,vectors):raise RuntimeError('Native descriptors failed')
    if not lib.negi_sensme_similarity_matrix(vectors,groups,matrix):raise RuntimeError('Native self similarity failed')
    actual=bytes(matrix);mismatches=0;differences=[]
    for offset in range(0,len(expected),2):
        if actual[offset:offset+2]!=expected[offset:offset+2]:
            mismatches+=1
            if len(differences)<24: differences.append(dict(row=offset//2//(groups-1),column=offset//2%(groups-1),
                                                         native=struct.unpack_from('<H',actual,offset)[0],reference=struct.unpack_from('<H',expected,offset)[0]))
    result=dict(exact=not mismatches,side=groups-1,cells=(groups-1)**2,mismatches=mismatches,firstDifferences=differences,
                nativeDispatchTonesExact=native_tones_exact)
    args.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    return 0 if result['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
