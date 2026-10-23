"""Run the audited repeated-section search on generated peak-ridge matrices."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from probe_integer_fir_windows import AUDITED_SHA256
from synthetic_coarse_input import KINDS,COUNTS,PHASES,inputs


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True);p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    if C.sizeof(C.c_void_p)!=4 or hashlib.sha256(args.dll.read_bytes()).hexdigest()!=AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and Windows x86 Python')
    k=C.WinDLL('kernel32',use_last_error=True);k.LoadLibraryW.argtypes=[C.c_wchar_p];k.LoadLibraryW.restype=C.c_void_p;k.FreeLibrary.argtypes=[C.c_void_p]
    module=k.LoadLibraryW(str(args.dll.resolve()))
    if not module:raise C.WinError(C.get_last_error())
    run=C.WINFUNCTYPE(C.c_uint32,C.c_void_p)(module+0x10f10);free=C.CFUNCTYPE(None,C.c_void_p)(module+0x28b3d);cases=[]
    try:
        for kind in KINDS:
            for count in COUNTS:
                for phase in PHASES:
                    matrix,numbers=inputs(kind,count,phase);source=(C.c_uint16*len(matrix)).from_buffer(matrix)
                    state=(C.c_uint32*(0x500//4))();beats=(C.c_ubyte*(count*168))()
                    state[0x474//4]=C.addressof(beats);state[0x478//4]=count;state[0x47c//4]=2
                    state[0x480//4]=count//2;state[0x488//4]=C.addressof(source)
                    for i,n in enumerate(numbers):C.c_int32.from_buffer(beats,i*168+8).value=n
                    try:
                        if run(state)&255!=1:raise RuntimeError('Original coarse search failed')
                        labels=[C.c_int32.from_buffer(beats,i*168+164).value for i in range(count)]
                        cases.append(dict(kind=kind,count=count,phase=phase,sectionCount=state[0x48c//4],
                                          labelsSHA256=hashlib.sha256(struct.pack('<'+'i'*count,*labels)).hexdigest(),labels=labels))
                    finally:free(state[0x484//4])
        args.out.write_text(json.dumps(dict(schemaVersion=1,input='self-generated symmetric peak-ridge matrices and beat numbers',cases=cases),indent=2)+'\n')
        print(json.dumps(dict(cases=len(cases),maxTypes=max(c['sectionCount'] for c in cases))))
    finally:k.FreeLibrary(module)


if __name__=='__main__':main()
