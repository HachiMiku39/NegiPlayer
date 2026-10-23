"""Observe the audited segment-key function on generated beat inputs only."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from probe_integer_fir_windows import AUDITED_SHA256
from synthetic_section_input import CLASS_KINDS,SECTION_KINDS,COUNTS,make


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True);p.add_argument('--out-prefix',type=Path,required=True)
    args=p.parse_args()
    if C.sizeof(C.c_void_p)!=4 or hashlib.sha256(args.dll.read_bytes()).hexdigest()!=AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and Windows x86 Python')
    k=C.WinDLL('kernel32',use_last_error=True)
    k.LoadLibraryW.argtypes=[C.c_wchar_p];k.LoadLibraryW.restype=C.c_void_p;k.FreeLibrary.argtypes=[C.c_void_p]
    module=k.LoadLibraryW(str(args.dll.resolve()))
    if not module:raise C.WinError(C.get_last_error())
    run=C.WINFUNCTYPE(C.c_uint32,C.c_void_p)(module+0x132e0);cases=[]
    try:
        for kind in CLASS_KINDS:
            for section_kind in SECTION_KINDS:
                for count in COUNTS:
                    classes,sections=make(kind,section_kind,count);beats=(C.c_ubyte*(count*168))();state=(C.c_uint32*(0x480//4))()
                    state[0x474//4]=C.addressof(beats);state[0x478//4]=count
                    for i in range(count):
                        C.c_int32.from_buffer(beats,i*168+12).value=classes[i]
                        C.c_int32.from_buffer(beats,i*168+164).value=sections[i]
                    before=bytes(beats)
                    if run(state)&255!=1:raise RuntimeError('Original key function failed')
                    after=bytes(beats);result=bytearray()
                    for i in range(count):
                        if before[i*168:i*168+112]!=after[i*168:i*168+112] or before[i*168+164:(i+1)*168]!=after[i*168+164:(i+1)*168]:
                            raise RuntimeError('Key function changed unrelated beat fields')
                        result.extend(after[i*168+112:i*168+164])
                    path=Path(str(args.out_prefix)+f'.{len(cases):02d}.bin');path.write_bytes(result)
                    cases.append(dict(kind=kind,sectionKind=section_kind,count=count,path=str(path),SHA256=hashlib.sha256(result).hexdigest()))
        Path(str(args.out_prefix)+'.json').write_text(json.dumps(dict(schemaVersion=1,dllSHA256=AUDITED_SHA256,input='self-generated tonal classes and section labels',cases=cases),indent=2)+'\n')
        print(json.dumps(dict(cases=len(cases),beats=sum(c['count'] for c in cases))))
    finally:k.FreeLibrary(module)


if __name__=='__main__':main()
