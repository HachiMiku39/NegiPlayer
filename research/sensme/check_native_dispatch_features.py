"""Verify native features using the full original pipeline's dispatch boundaries."""
import argparse
import array
import ctypes as C
import hashlib
import json
from pathlib import Path
from check_native_spectral_stats import local_path


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--default-bank',action='store_true');args=p.parse_args()
    report=json.loads(args.report.read_text());raw=local_path(report['monoInputPath']).read_bytes()
    expected=local_path(report['energyBlocksPath']).read_bytes()
    if hashlib.sha256(raw).hexdigest()!=report['monoInputSHA256']:raise ValueError('PCM digest differs')
    if hashlib.sha256(expected).hexdigest()!=report['energySHA256']:raise ValueError('Energy digest differs')
    partitions=report['pcmPartitions']
    if sum(partitions)*2!=len(raw) or any(n<1 or n>4096 for n in partitions):raise ValueError('Invalid dispatch boundaries')
    words=array.array('h');words.frombytes(raw)
    lib=C.CDLL(str(args.library.resolve()));callback_type=C.CFUNCTYPE(C.c_int,C.c_void_p,C.POINTER(C.c_uint16))
    lib.negi_sensme_features_create.argtypes=[C.POINTER(C.c_int16),callback_type,C.c_void_p]
    lib.negi_sensme_features_create.restype=C.c_void_p
    lib.negi_sensme_features_create_default.argtypes=[callback_type,C.c_void_p]
    lib.negi_sensme_features_create_default.restype=C.c_void_p
    lib.negi_sensme_features_destroy.argtypes=[C.c_void_p]
    lib.negi_sensme_features_write.argtypes=[C.c_void_p,C.POINTER(C.c_int16),C.c_size_t]
    frames=bytearray()
    @callback_type
    def emit(context,pointer):frames.extend(C.string_at(pointer,144));return 1
    if args.default_bank:state=lib.negi_sensme_features_create_default(emit,None)
    else:
        coefficients=(C.c_int16*(12*47))(*[v for row in report['configuration']['toneFilters'] for v in row])
        state=lib.negi_sensme_features_create(coefficients,emit,None)
    if not state:raise RuntimeError('Allocation failed')
    try:
        at=0
        for count in partitions:
            source=(C.c_int16*count).from_buffer(words,at*2)
            if not lib.negi_sensme_features_write(state,source,count):raise RuntimeError('Feature write failed')
            at+=count
    finally:lib.negi_sensme_features_destroy(state)
    actual=frames[292*144:292*144+len(expected)]
    result=dict(exact=actual==expected,rawFrames=len(frames)//144,comparedFrames=len(expected)//144,
                dispatchBlocks=len(partitions),nativeSHA256=hashlib.sha256(actual).hexdigest(),referenceSHA256=report['energySHA256'],
                embeddedDefaultBank=args.default_bank)
    args.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    return 0 if result['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
