"""Compare native tonal probabilities with the synthetic DLL oracle."""
import argparse
import ctypes as C
import json
from pathlib import Path
import struct
from synthetic_tonal_input import make


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    report=json.loads(args.report.read_text());lib=C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_tonal_features.argtypes=[C.POINTER(C.c_uint16),C.POINTER(C.c_uint16),C.c_size_t,C.c_size_t,C.c_size_t,C.POINTER(C.c_float)]
    differences=[];previous=None
    for case in report['cases']:
        if case['kind']!=previous:
            groups=make(case['kind']);buffers=[(C.c_uint16*len(g)).from_buffer(g) for g in groups];previous=case['kind']
        output=(C.c_float*24)();selected=lib.negi_sensme_tonal_features(*buffers,19008,case['start'],case['frames'],output)
        words=list(struct.unpack('<24I',bytes(output)))
        if words!=case['words'] or selected!=case['selected']:
            differences.append(dict(kind=case['kind'],start=case['start'],frames=case['frames'],
                                    selected=[selected,case['selected']],
                                    words={str(i):[hex(a),hex(b)] for i,(a,b) in enumerate(zip(words,case['words'])) if a!=b}))
    result=dict(exact=not differences,cases=len(report['cases']),differences=differences)
    args.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    return 0 if result['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
