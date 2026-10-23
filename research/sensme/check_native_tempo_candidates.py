"""Compare native onset-to-candidate stages with full-analysis observations."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
from check_native_accumulator import compare
from check_native_spectral_stats import local_path


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    p.add_argument('--onset-prefix',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--refinement-report',type=Path,help='Also compare accumulated band-2 spectrum spread to state+0x470')
    args=p.parse_args();report=json.loads(args.report.read_text())
    if len(report['segments'])%3:raise ValueError('Expected three bands')
    segments=len(report['segments'])//3
    lib=C.CDLL(str(args.library.resolve()));lib.negi_sensme_fft_create.argtypes=[C.c_size_t]
    lib.negi_sensme_fft_create.restype=C.c_void_p
    lib.negi_sensme_fft_destroy.argtypes=[C.c_void_p]
    lib.negi_sensme_fft_real.argtypes=[C.c_void_p,C.POINTER(C.c_float),C.POINTER(C.c_float)]
    lib.negi_sensme_tempo_candidate.argtypes=[C.POINTER(C.c_float),C.POINTER(C.c_float)]
    lib.negi_sensme_tempo_candidate_seeded.argtypes=[C.POINTER(C.c_float),C.POINTER(C.c_float),C.c_int]
    lib.negi_sensme_tempo_spectrum_accumulate.argtypes=[C.POINTER(C.c_float),C.POINTER(C.c_float)]
    lib.negi_sensme_tempo_spectrum_spread.argtypes=[C.POINTER(C.c_float),C.POINTER(C.c_float)]
    state=lib.negi_sensme_fft_create(4096)
    if not state:raise RuntimeError('Allocation failed')
    results=[];profile=(C.c_float*256)();previous=0
    try:
        for band in range(3):
            raw=Path(str(args.onset_prefix)+f'.onsets-{band}.bin').read_bytes()
            for segment in range(segments):
                payload=raw[segment*4096*4:(segment+1)*4096*4].ljust(4096*4,b'\0')
                source=(C.c_float*4096).from_buffer_copy(payload);packed=(C.c_float*4096)();magnitudes=(C.c_float*2049)()
                if not lib.negi_sensme_fft_real(state,source,packed):raise RuntimeError('FFT failed')
                candidate=lib.negi_sensme_tempo_candidate_seeded(packed,magnitudes,previous)
                previous=candidate
                if band==2 and not lib.negi_sensme_tempo_spectrum_accumulate(magnitudes,profile):raise RuntimeError('Profile accumulation failed')
                reference=report['segments'][band*segments+segment]
                expected=local_path(reference['path']).read_bytes()
                if hashlib.sha256(expected).hexdigest()!=reference['SHA256']:raise ValueError('Reference digest differs')
                results.append(dict(band=band,segment=segment,candidate=candidate,referenceCandidate=reference['candidate'],**compare(bytes(magnitudes),expected,4)))
    finally:lib.negi_sensme_fft_destroy(state)
    result=dict(exact=all(x['mismatches']==0 and x['candidate']==x['referenceCandidate'] for x in results),segments=results)
    if args.refinement_report:
        import struct
        trace=json.loads(args.refinement_report.read_text())
        if trace['dllSHA256']!=report['dllSHA256'] or trace['pcmSHA256']!=report['pcmSHA256']:raise ValueError('Spread reference input differs')
        stage=next(v for v in trace['observations'] if v['stage']=='final_phase')
        expected=struct.unpack_from('<I',local_path(stage['statePath']).read_bytes(),0x470)[0]
        spread=C.c_float()
        if not lib.negi_sensme_tempo_spectrum_spread(profile,C.byref(spread)):raise RuntimeError('Spread failed')
        bits=struct.unpack('<I',bytes(spread))[0]
        result.update(spectrumSpreadBits=bits,referenceSpectrumSpreadBits=expected,spectrumProfileSHA256=hashlib.sha256(bytes(profile)).hexdigest())
        result['exact']=result['exact'] and bits==expected
    args.out.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(exact=result['exact'],segments=len(results),failures=[x for x in results if x['mismatches'] or x['candidate']!=x['referenceCandidate']])))
    return 0 if result['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
