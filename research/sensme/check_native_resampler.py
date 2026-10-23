"""Compare native analysis resampling with observed synthetic DLL output."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
from probe_resampler_windows import resampler_input
from probe_pcm_windows import partitions


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library',type=Path,required=True)
    parser.add_argument('--oracle',type=Path,required=True)
    args=parser.parse_args()
    lib=C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_resampler_create.argtypes=[C.c_double];lib.negi_sensme_resampler_create.restype=C.c_void_p
    lib.negi_sensme_resampler_destroy.argtypes=[C.c_void_p];lib.negi_sensme_resampler_destroy.restype=None
    lib.negi_sensme_resampler_available.argtypes=[C.c_void_p];lib.negi_sensme_resampler_available.restype=C.c_size_t
    for name in ['write','read']:
        f=getattr(lib,'negi_sensme_resampler_'+name)
        f.argtypes=[C.c_void_p,C.POINTER(C.c_float),C.c_size_t];f.restype=C.c_int
    results=[]
    for case in json.loads(args.oracle.read_text())['cases']:
        samples=resampler_input(case['inputFrames'])
        state=lib.negi_sensme_resampler_create(case['ratio'])
        if not state: raise RuntimeError('Create failed')
        try:
            digest=hashlib.sha256();frames=0
            for at,count in partitions(len(samples)):
                block=(C.c_float*count)(*samples[at:at+count])
                if not lib.negi_sensme_resampler_write(state,block,count):raise AssertionError('Write failed')
                count=lib.negi_sensme_resampler_available(state)
                if count:
                    out=(C.c_float*count)()
                    if not lib.negi_sensme_resampler_read(state,out,count):raise AssertionError('Read failed')
                    digest.update(bytes(out));frames+=count
            sentinel=(C.c_float*3)(-9,-9,-9)
            if lib.negi_sensme_resampler_read(state,sentinel,3) or bytes(sentinel)!=b'\0'*12:
                raise AssertionError('Insufficient-input behavior differs')
            result=dict(ratio=case['ratio'],outputFrames=frames,sha256=digest.hexdigest(),
                        finalAvailable=lib.negi_sensme_resampler_available(state))
            expected={k:case[k] for k in result}
            if result!=expected:raise AssertionError((result,expected))
            results.append(result)
        finally:lib.negi_sensme_resampler_destroy(state)
    print(json.dumps(dict(cases=len(results),exact=True,results=results)))


if __name__=='__main__':main()
