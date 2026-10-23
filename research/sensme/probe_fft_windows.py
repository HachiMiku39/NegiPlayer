"""Generate analysis FFT references using synthetic float input only."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from probe_integer_fir_windows import AUDITED_SHA256


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True);p.add_argument('--out-prefix',type=Path,required=True)
    p.add_argument('--input-floats',type=Path,help='Private onset floats; verify complete 4096-frame segments (up to ten)')
    args=p.parse_args()
    if C.sizeof(C.c_void_p)!=4 or hashlib.sha256(args.dll.read_bytes()).hexdigest()!=AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and Windows x86 Python')
    k=C.WinDLL('kernel32',use_last_error=True)
    k.LoadLibraryW.argtypes=[C.c_wchar_p];k.LoadLibraryW.restype=C.c_void_p
    k.VirtualAlloc.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.c_uint32];k.VirtualAlloc.restype=C.c_void_p
    k.VirtualProtect.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_uint32)]
    k.VirtualFree.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32]
    k.GetCurrentProcess.restype=C.c_void_p;k.FlushInstructionCache.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t]
    module=k.LoadLibraryW(str(args.dll.resolve()))
    if not module:raise C.WinError(C.get_last_error())
    pages=[]
    def thunk(body,prototype):
        code=b'\x55\x89\xe5\x57'+body+b'\x5f\x89\xec\x5d\xc3'
        page=k.VirtualAlloc(None,len(code),0x3000,4)
        if not page:raise C.WinError(C.get_last_error())
        pages.append(page);C.memmove(page,code,len(code));old=C.c_uint32()
        if not k.VirtualProtect(page,len(code),0x20,C.byref(old)):raise C.WinError(C.get_last_error())
        k.FlushInstructionCache(k.GetCurrentProcess(),page,len(code));return prototype(page)
    create=thunk(b'\x8b\x7d\x08\xff\x75\x0c\xb8'+struct.pack('<I',module+0x15c70)+b'\xff\xd0',
                 C.CFUNCTYPE(None,C.c_void_p,C.c_int32))
    run=thunk(b'\x8b\x7d\x08\xff\x75\x10\xff\x75\x0c\xb8'+struct.pack('<I',module+0x15d00)+b'\xff\xd0',
              C.CFUNCTYPE(None,C.c_void_p,C.c_void_p,C.c_void_p))
    free=C.CFUNCTYPE(None,C.c_void_p)(module+0x28b3d)
    cases=[]
    try:
        sizes=[4096] if args.input_floats else [2,4,8,16,32,64,256,1024,4096]
        private=args.input_floats.read_bytes() if args.input_floats else None
        if private is not None and (len(private)%4 or len(private)<4096*4):raise ValueError('Private input needs complete float32 segments')
        for count in sizes:
            plan=(C.c_uint32*3)();create(plan,count)
            try:
                kinds=[f'private-{i}' for i in range(min(10,len(private)//(4096*4)))] if private is not None else ['zero','impulse','random','alternating','ramp']
                for kind in kinds:
                    seed=0x39f17e;values=[]
                    for i in range(count):
                        seed=(1664525*seed+1013904223)&0xffffffff
                        value=0 if kind=='zero' else (1 if i==0 else 0) if kind=='impulse' else ((seed>>16)-32768)/128 if kind=='random' else (8192 if i%2 else -8192) if kind=='alternating' else (i%257-128)/64
                        values.append(value)
                    source=(C.c_float*count)(*values);output=(C.c_float*count)();run(plan,source,output)
                    if private is not None:
                        block=int(kind.split('-')[1]);source=(C.c_float*count).from_buffer_copy(private[block*count*4:(block+1)*count*4])
                        run(plan,source,output)
                    path=Path(str(args.out_prefix)+f'.{count}-{kind}.f32le');path.write_bytes(bytes(output))
                    case=dict(count=count,kind=kind,path=str(path),SHA256=hashlib.sha256(bytes(output)).hexdigest())
                    if private is not None:case.update(inputPath=str(args.input_floats),inputSHA256=hashlib.sha256(private).hexdigest())
                    cases.append(case)
            finally:free(plan[2])
        Path(str(args.out_prefix)+'.json').write_text(json.dumps(dict(dllSHA256=AUDITED_SHA256,cases=cases),indent=2)+'\n')
        print(json.dumps(dict(cases=len(cases))))
    finally:
        for page in pages:k.VirtualFree(page,0,0x8000)


if __name__=='__main__':main()
