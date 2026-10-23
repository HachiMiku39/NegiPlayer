"""Check segment keys against generated or private full-process references."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from check_native_spectral_stats import local_path
from synthetic_section_input import make


class Key(C.Structure):
    _fields_=[('root',C.c_int32),('probabilities',C.c_float*12)]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--full-reference',action='store_true');args=p.parse_args()
    report=json.loads(args.report.read_text());lib=C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_section_keys.argtypes=[C.POINTER(C.c_int32),C.POINTER(C.c_int32),C.c_size_t,C.POINTER(Key)]
    differences=[];total=0
    if args.full_reference:
        if not report['unobservedVerified']:raise ValueError('Full reference was not verified')
        stages={x['stage']:x for x in report['observations']}
        before=local_path(stages['refined_sections']['beatsPath']).read_bytes()
        after=local_path(stages['section_keys_ready']['beatsPath']).read_bytes()
        if len(before)!=len(after) or len(before)%168:raise ValueError('Full beat count differs')
        n=len(before)//168;classes=[struct.unpack_from('<i',before,i*168+12)[0] for i in range(n)]
        sections=[struct.unpack_from('<i',before,i*168+164)[0] for i in range(n)]
        expected=bytearray()
        for i in range(n):
            if before[i*168:i*168+112]!=after[i*168:i*168+112] or before[i*168+164:(i+1)*168]!=after[i*168+164:(i+1)*168]:
                raise ValueError('Full key stage changed unrelated fields')
            expected.extend(after[i*168+112:i*168+164])
        cases=[dict(kind='private',sectionKind='observed',count=n)]
    else:cases=report['cases']
    for case in cases:
        if not args.full_reference:
            classes,sections=make(case['kind'],case['sectionKind'],case['count'])
            expected=local_path(case['path']).read_bytes()
            if hashlib.sha256(expected).hexdigest()!=case['SHA256']:raise ValueError('Reference digest differs')
        n=case['count'];output=(Key*n)()
        if not lib.negi_sensme_section_keys((C.c_int32*n)(*classes),(C.c_int32*n)(*sections),n,output):raise RuntimeError('Native section keys failed')
        actual=bytes(output);total+=n
        if actual!=expected:
            words=[]
            for i in range(0,len(expected),4):
                if actual[i:i+4]!=expected[i:i+4]:
                    words.append(dict(beat=i//52,word=(i%52)//4,native=actual[i:i+4].hex(),reference=expected[i:i+4].hex()))
            differences.append(dict(kind=case['kind'],sectionKind=case['sectionKind'],count=n,differences=words))
    result=dict(exact=not differences,cases=len(cases),beats=total,differences=differences)
    args.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    return 0 if result['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
