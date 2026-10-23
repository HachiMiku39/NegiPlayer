"""Compare synthetic full-process beat grids and export portable golden data."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from check_native_beat_tonal import Beat,GridSummary
from check_native_spectral_stats import local_path
from synthetic_tonal_input import make


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--reports',type=Path,nargs='+',required=True)
    p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    lib=C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_beat_grid.argtypes=[C.POINTER(C.c_uint16),C.POINTER(C.c_uint16),C.c_size_t,C.c_float,C.c_float,
                                       C.POINTER(Beat),C.c_size_t,C.POINTER(GridSummary)]
    cases=[]
    for path in args.reports:
        report=json.loads(path.read_text());spec=report['syntheticInput']
        if not report['unobservedVerified']:raise ValueError('Observation was not verified')
        stages={o['stage']:o for o in report['observations']}
        groups=make(spec['toneKind'])
        if [hashlib.sha256(g.tobytes()).hexdigest() for g in groups]!=spec['toneSHA256']:raise ValueError('Generated tones differ')
        sources=[(C.c_uint16*len(g)).from_buffer(g) for g in groups]
        frame=local_path(stages['grid_allocation']['framePath']).read_bytes()
        period=struct.unpack_from('<f',frame,0x30)[0];phase=struct.unpack_from('<f',frame,0x1c)[0]
        output=(Beat*960)();summary=GridSummary()
        if not lib.negi_sensme_beat_grid(*sources,spec['frames'],period,phase,output,960,C.byref(summary)):raise RuntimeError('Native grid failed')
        actual=bytes(output)[:summary.count*168];expected=local_path(stages['grid_final']['beatsPath']).read_bytes()
        candidate_stack=local_path(stages['grid_candidates']['framePath']).read_bytes()
        expected_scores=candidate_stack[0x304:0x314];actual_scores=struct.pack('<4f',*summary.downbeat_scores)
        exact=(actual==expected and expected_scores==actual_scores and summary.downbeat_offset==stages['grid_candidates']['registers'][1])
        if not exact:raise RuntimeError(f'Synthetic grid differs: {spec["case"]}')
        cases.append(dict(kind=spec['toneKind'],frames=spec['frames'],
            periodBits=struct.unpack_from('<I',frame,0x30)[0],phaseBits=struct.unpack_from('<I',frame,0x1c)[0],
            preliminaryCount=summary.preliminary_count,count=summary.count,downbeatOffset=summary.downbeat_offset,
            scoreBits=list(struct.unpack('<4I',expected_scores)),
            alignedPhaseBits=struct.unpack('<I',struct.pack('<f',summary.aligned_phase_frames))[0],
            gridSHA256=hashlib.sha256(expected).hexdigest(),observationPreservedFullResult=True,nativeExact=True))
    args.out.write_text(json.dumps(dict(schemaVersion=1,input='self-generated compressed tones and onset/statistics inputs',cases=cases),indent=2)+'\n')
    print(json.dumps(dict(exact=True,cases=len(cases),beats=sum(c['count'] for c in cases))))


if __name__=='__main__':main()
