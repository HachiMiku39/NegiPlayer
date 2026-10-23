"""Find exact float32 boundaries of the original x87 likelihood underflow."""
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
    p.add_argument('--dll',type=Path,required=True);p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    if C.sizeof(C.c_void_p)!=4 or hashlib.sha256(args.dll.read_bytes()).hexdigest()!=AUDITED_SHA256:raise RuntimeError('Audited DLL and x86 Python required')
    k=C.WinDLL('kernel32',use_last_error=True);k.LoadLibraryW.argtypes=[C.c_wchar_p];k.LoadLibraryW.restype=C.c_void_p
    k.FreeLibrary.argtypes=[C.c_void_p];k.VirtualAlloc.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.c_uint32];k.VirtualAlloc.restype=C.c_void_p
    k.VirtualProtect.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_uint32)];k.VirtualFree.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32]
    k.GetCurrentProcess.restype=C.c_void_p;k.FlushInstructionCache.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t]
    module=k.LoadLibraryW(str(args.dll.resolve()));page=None
    if not module:raise C.WinError(C.get_last_error())
    code=(b'\x55\x89\xe5\x8b\x45\x08\x89\xc1'+b''.join(b'\x68'+struct.pack('<I',v) for v in [0x4106e628,0x42349154,0x40b4449a,0x428526b9])
          +b'\xba'+struct.pack('<I',module+0x17340)+b'\xff\xd2\x89\xec\x5d\xc3')
    control_offset=len(code);code+=b'\x6a\x00\xd9\x3c\x24\x58\xc3'
    try:
        page=k.VirtualAlloc(None,len(code),0x3000,4)
        if not page:raise C.WinError(C.get_last_error())
        C.memmove(page,code,len(code));old=C.c_uint32()
        if not k.VirtualProtect(page,len(code),0x20,C.byref(old)):raise C.WinError(C.get_last_error())
        k.FlushInstructionCache(k.GetCurrentProcess(),page,len(code));run=C.CFUNCTYPE(None,C.c_void_p)(page)
        control_word=C.CFUNCTYPE(C.c_uint32)(page+control_offset)()
        data=C.c_uint32();shape=(C.c_uint32*2)(1,0);header=(C.c_uint32*5)(C.addressof(data),1,1,C.addressof(shape),0)
        def apply(bits):data.value=bits;run(header);return data.value
        def bits(value):return struct.unpack('<I',struct.pack('<f',value))[0]
        boundaries=[];cases=[]
        for sign in [0,0x80000000]:
            low,high=bits(256),bits(5000)
            if apply(high|sign)!=(high|sign) or apply(low|sign)==(low|sign):raise ValueError('Underflow bracket differs')
            while low+1<high:
                mid=(low+high)//2
                if apply(mid|sign)==(mid|sign):high=mid
                else:low=mid
            boundaries.append(high|sign)
            for step in range(-16,17):
                value=(high+step)|sign;cases.append(dict(inputBits=value,outputBits=apply(value)))
        seed=0x39c0a055
        for i in range(16384):
            seed=(1664525*seed+1013904223)&0xffffffff
            value=((seed>>8)%10000000-5000000)/1024
            word=bits(value);cases.append(dict(inputBits=word,outputBits=apply(word)))
        args.out.write_text(json.dumps(dict(schemaVersion=1,dllSHA256=AUDITED_SHA256,analysisVersion='1.6.1',x87ControlWord=control_word,firstFallbackBits=boundaries,cases=cases),indent=2)+'\n')
        print(json.dumps(dict(cases=len(cases),x87ControlWord=hex(control_word),firstFallbackBits=[hex(v) for v in boundaries],values=[struct.unpack('<f',struct.pack('<I',v))[0] for v in boundaries])))
    finally:
        if page:k.VirtualFree(page,0,0x8000)
        k.FreeLibrary(module)


if __name__=='__main__':main()
