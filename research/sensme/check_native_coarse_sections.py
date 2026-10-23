"""Check native repeated-section labels against full-process observations."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from check_native_spectral_stats import local_path
from synthetic_coarse_input import inputs


def synthetic(lib,report):
    cases=[]
    for case in report['cases']:
        raw,numbers=inputs(case['kind'],case['count'],case['phase']);count=case['count']
        source=(C.c_uint16*len(raw)).from_buffer(raw);beats=(C.c_int32*count)(*numbers);output=(C.c_int32*count)();types=C.c_size_t()
        original=bytes(source)
        if not lib.negi_sensme_coarse_sections(source,count,beats,output,C.byref(types)):raise RuntimeError('Generated coarse search failed')
        if bytes(source)!=original:raise RuntimeError('Input matrix changed')
        expected=struct.pack('<'+'i'*count,*case['labels'])
        if hashlib.sha256(expected).hexdigest()!=case['labelsSHA256']:raise ValueError('Generated reference digest differs')
        differences=[dict(beat=i,native=a,reference=b) for i,(a,b) in enumerate(zip(output,case['labels'])) if a!=b]
        cases.append(dict(kind=case['kind'],count=count,phase=case['phase'],types=[types.value,case['sectionCount']],
                          mismatchCount=len(differences),firstDifferences=differences[:12]))
    return dict(exact=all(not c['mismatchCount'] and c['types'][0]==c['types'][1] for c in cases),cases=cases)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--synthetic',action='store_true');args=p.parse_args()
    report=json.loads(args.report.read_text())
    lib=C.CDLL(str(args.library.resolve()));lib.negi_sensme_coarse_sections.argtypes=[C.POINTER(C.c_uint16),C.c_size_t,C.POINTER(C.c_int32),C.POINTER(C.c_int32),C.POINTER(C.c_size_t)]
    if args.synthetic:
        result=synthetic(lib,report);args.out.write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(dict(exact=result['exact'],cases=len(result['cases']),differences=[c for c in result['cases'] if c['mismatchCount'] or c['types'][0]!=c['types'][1]])))
        return 0 if result['exact'] else 1
    if not report['unobservedVerified']:raise ValueError('Observation was not verified')
    stages={s['stage']:s for s in report['observations']};source=stages['self_similarity_ready'];target=stages['coarse_sections']
    raw=local_path(source['matrixPath']).read_bytes()
    if hashlib.sha256(raw).hexdigest()!=source['matrixSHA256']:raise ValueError('Matrix digest differs')
    before=local_path(source['beatsPath']).read_bytes();after=local_path(target['beatsPath']).read_bytes();state=local_path(target['statePath']).read_bytes()
    count=len(before)//168;expected=[struct.unpack_from('<i',after,i*168+164)[0] for i in range(count)]
    beats=(C.c_int32*count)(*[struct.unpack_from('<i',before,i*168+8)[0] for i in range(count)])
    matrix=(C.c_uint16*(len(raw)//2)).from_buffer_copy(raw);output=(C.c_int32*count)();types=C.c_size_t()
    if not lib.negi_sensme_coarse_sections(matrix,count,beats,output,C.byref(types)):raise RuntimeError('Native coarse sections failed')
    if bytes(matrix)!=raw:raise RuntimeError('Native search changed its input matrix')
    differences=[dict(beat=i,native=a,reference=b) for i,(a,b) in enumerate(zip(output,expected)) if a!=b]
    expected_types=struct.unpack_from('<I',state,0x48c)[0]
    result=dict(exact=not differences and types.value==expected_types,beats=count,types=[types.value,expected_types],differences=differences)
    args.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    return 0 if result['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
