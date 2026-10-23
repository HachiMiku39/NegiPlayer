"""Private-process tonal oracle, using generated uint16 stage inputs only.

Calls the audited compressed-tone path directly. Reads the DLL without
modifying it; no song, VM snapshot or Windows dependency belongs in the app.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from probe_integer_fir_windows import AUDITED_SHA256
from synthetic_tonal_input import KINDS,RANGES,make


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    args=p.parse_args()
    if C.sizeof(C.c_void_p)!=4 or hashlib.sha256(args.dll.read_bytes()).hexdigest()!=AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and Windows x86 Python')
    k=C.WinDLL('kernel32',use_last_error=True)
    k.LoadLibraryW.argtypes=[C.c_wchar_p];k.LoadLibraryW.restype=C.c_void_p
    k.FreeLibrary.argtypes=[C.c_void_p]
    module=k.LoadLibraryW(str(args.dll.resolve()))
    if not module:raise C.WinError(C.get_last_error())
    run=C.WINFUNCTYPE(C.c_int32,C.c_void_p,C.c_int32,C.c_int32,C.c_void_p)(module+0x12a80)
    cases=[]
    try:
        state=(C.c_uint32*(0x128//4))();record=(C.c_uint32*(0x130//4))()
        state[0x11c//4]=38016;state[0x124//4]=C.addressof(record);record[0x10c//4]=1
        for kind in KINDS:
            groups=make(kind);buffers=[(C.c_uint16*len(g)).from_buffer(g) for g in groups]
            record[0x110//4]=C.addressof(buffers[0]);record[0x114//4]=C.addressof(buffers[1])
            for start,length in RANGES:
                output=(C.c_float*24)();selected=run(state,start,length,output)
                cases.append(dict(kind=kind,start=start,frames=length,selected=selected,
                                  words=list(C.cast(output,C.POINTER(C.c_uint32*24)).contents)))
        report=dict(schemaVersion=1,dllSHA256=AUDITED_SHA256,input='self-generated compressed tone inputs',cases=cases)
        args.out.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(cases=len(cases))))
    finally:k.FreeLibrary(module)


if __name__=='__main__':main()
