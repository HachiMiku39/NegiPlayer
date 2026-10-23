"""Compare native FFT output against the audited synthetic reference bytes."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
from check_native_accumulator import compare
from check_native_spectral_stats import local_path


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--oracle',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    lib=C.CDLL(str(args.library.resolve()));lib.negi_sensme_fft_create.argtypes=[C.c_size_t]
    lib.negi_sensme_fft_create.restype=C.c_void_p
    lib.negi_sensme_fft_destroy.argtypes=[C.c_void_p]
    lib.negi_sensme_fft_real.argtypes=[C.c_void_p,C.POINTER(C.c_float),C.POINTER(C.c_float)]
    results=[]
    for case in json.loads(args.oracle.read_text())['cases']:
        count=case['count'];kind=case['kind'];seed=0x39f17e;values=[]
        for i in range(count):
            seed=(1664525*seed+1013904223)&0xffffffff
            value=0 if kind=='zero' else (1 if i==0 else 0) if kind=='impulse' else ((seed>>16)-32768)/128 if kind=='random' else (8192 if i%2 else -8192) if kind=='alternating' else (i%257-128)/64
            values.append(value)
        state=lib.negi_sensme_fft_create(count)
        if not state:raise RuntimeError('Allocation failed')
        try:
            source=(C.c_float*count)(*values);output=(C.c_float*count)()
            if kind.startswith('private-'):
                private=local_path(case['inputPath']).read_bytes();block=int(kind.split('-')[1])
                if hashlib.sha256(private).hexdigest()!=case['inputSHA256']:raise ValueError('Private input digest differs')
                source=(C.c_float*count).from_buffer_copy(private[block*count*4:(block+1)*count*4])
            if not lib.negi_sensme_fft_real(state,source,output):raise RuntimeError('FFT failed')
            expected=local_path(case['path']).read_bytes()
            if hashlib.sha256(expected).hexdigest()!=case['SHA256']:raise ValueError('Reference digest differs')
            results.append(dict(count=count,kind=kind,**compare(bytes(output),expected,4)))
        finally:lib.negi_sensme_fft_destroy(state)
    result=dict(exact=all(x['mismatches']==0 for x in results),cases=results)
    args.out.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(exact=result['exact'],cases=len(results),failures=[x for x in results if x['mismatches']])))
    return 0 if result['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
