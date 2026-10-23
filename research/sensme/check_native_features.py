"""Compare native raw feature frames with synthetic DLL oracles."""
import argparse
import array
import ctypes as C
import hashlib
import json
from pathlib import Path
from probe_features_windows import feature_input,feature_partitions,synthetic_tones,load_mono_pcm


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--config',type=Path)
    p.add_argument('--oracle',type=Path,required=True)
    p.add_argument('--pcm',type=Path)
    p.add_argument('--frames-out',type=Path)
    args=p.parse_args();lib=C.CDLL(str(args.library.resolve()))
    if args.frames_out and not args.pcm:p.error('--frames-out requires --pcm')
    callbackType=C.CFUNCTYPE(C.c_int,C.c_void_p,C.POINTER(C.c_uint16))
    lib.negi_sensme_features_create.argtypes=[C.POINTER(C.c_int16),callbackType,C.c_void_p]
    lib.negi_sensme_features_create.restype=C.c_void_p
    lib.negi_sensme_features_write.argtypes=[C.c_void_p,C.POINTER(C.c_int16),C.c_size_t]
    lib.negi_sensme_features_write.restype=C.c_int
    lib.negi_sensme_features_destroy.argtypes=[C.c_void_p];lib.negi_sensme_features_destroy.restype=None
    oracle=json.loads(args.oracle.read_text())
    if oracle.get('toneSource')=='synthetic':rows=synthetic_tones()
    elif args.config:rows=json.loads(args.config.read_text())['toneFilters']
    else:p.error('--config is required for audited default coefficients')
    coefficients=[v for row in rows for v in row]
    tones=(C.c_int16*len(coefficients))(*coefficients)
    results=[]
    for case in oracle['cases']:
        digest=hashlib.sha256();post=hashlib.sha256();frames=0;nonzero=-1
        raw_output=None
        @callbackType
        def emit(context,pointer):
            nonlocal frames,nonzero
            payload=C.string_at(pointer,144);digest.update(payload)
            if raw_output:raw_output.write(payload)
            if frames>=292:post.update(payload)
            if nonzero<0 and any(payload):nonzero=frames
            frames+=1;return 1
        state=lib.negi_sensme_features_create(tones,emit,None)
        if not state:raise RuntimeError('Native feature allocation failed')
        try:
            if case['kind']=='pcm':
                if not args.pcm:p.error('--pcm is required for a PCM oracle')
                samples,pcm_hash=load_mono_pcm(args.pcm)
                if pcm_hash!=case['pcmSHA256']:raise ValueError('PCM source digest differs from oracle')
            else:samples=feature_input(case['kind'],case['inputFrames'])
            if args.frames_out:raw_output=args.frames_out.open('wb')
            for at,count in feature_partitions(len(samples),case.get('blockFrames',0)):
                source=((C.c_int16*count).from_buffer(samples,at*2) if isinstance(samples,array.array)
                        else (C.c_int16*count)(*samples[at:at+count]))
                if not lib.negi_sensme_features_write(state,source,count):raise RuntimeError('Native write failed')
            result=dict(kind=case['kind'],inputFrames=len(samples),rawFrames=frames,startupFrames=292,
                        sha256=digest.hexdigest(),postStartupSHA256=post.hexdigest(),firstNonzero=nonzero)
            if case['kind']=='pcm':result['pcmSHA256']=pcm_hash
            if any(value!=case.get(key) for key,value in result.items()):raise AssertionError((result,case))
            results.append(result)
        finally:
            if raw_output:raw_output.close()
            lib.negi_sensme_features_destroy(state)
    print(json.dumps(dict(cases=len(results),exact=True,results=results)))


if __name__=='__main__':main()
