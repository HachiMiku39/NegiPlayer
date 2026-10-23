"""Inspect the audited default feature-bank configuration on synthetic state.

Local reference data; not a complete analysis engine or application backend.
"""
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
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    if C.sizeof(C.c_void_p)!=4 or hashlib.sha256(args.dll.read_bytes()).hexdigest()!=AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and x86 Python')
    k=C.WinDLL('kernel32',use_last_error=True)
    k.LoadLibraryW.argtypes=[C.c_wchar_p];k.LoadLibraryW.restype=C.c_void_p
    k.VirtualAlloc.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.c_uint32];k.VirtualAlloc.restype=C.c_void_p
    k.VirtualProtect.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_uint32)]
    k.VirtualFree.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32]
    k.GetCurrentProcess.restype=C.c_void_p
    k.FlushInstructionCache.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t]
    module=k.LoadLibraryW(str(args.dll.resolve()))
    if not module:raise C.WinError(C.get_last_error())
    pages=[]
    def thunk(code,prototype):
        page=k.VirtualAlloc(None,len(code),0x3000,4)
        if not page:raise C.WinError(C.get_last_error())
        pages.append(page);C.memmove(page,code,len(code));old=C.c_uint32()
        if not k.VirtualProtect(page,len(code),0x20,C.byref(old)):raise C.WinError(C.get_last_error())
        k.FlushInstructionCache(k.GetCurrentProcess(),page,len(code))
        return prototype(page)
    # cdecl(this, sampleRate, octaves), ECX=256, EDX=47 -> internal ctor.
    ctor=(b'\x55\x89\xe5\xb9'+struct.pack('<I',256)+b'\xba'+struct.pack('<I',47)
          +b'\xff\x75\x10\xff\x75\x0c\xff\x75\x08\xb8'+struct.pack('<I',module+0x24d70)
          +b'\xff\xd0\x89\xec\x5d\xc3')
    destroy=(b'\x55\x89\xe5\x8b\x4d\x08\x6a\x00\xb8'+struct.pack('<I',module+0x25560)
             +b'\xff\xd0\x89\xec\x5d\xc3')
    try:
        create=thunk(ctor,C.CFUNCTYPE(C.c_void_p,C.c_void_p,C.c_uint32,C.c_uint32))
        release=thunk(destroy,C.CFUNCTYPE(None,C.c_void_p))
        obj=(C.c_ubyte*0xcd4)()
        address=C.addressof(obj)
        result=create(address,44100,6)
        if result!=address:raise RuntimeError('Unexpected constructor result')
        try:
            def u32(offset):return C.c_uint32.from_address(address+offset).value
            def array_at(pointer,kind,count):return list((kind*count).from_address(pointer))
            resampler=u32(0xcc0)
            value=dict(schemaVersion=1,dllSHA256=AUDITED_SHA256,sourceRate=44100,
                       octaves=u32(0xcc4),lowpassTaps=u32(0xcc8),toneTaps=u32(0xccc),
                       startupFrames=u32(0xcd0),
                       resamplerRatio=C.c_double.from_address(resampler+8).value,
                       resamplerStep=C.c_double.from_address(resampler+0x28).value,
                       resamplerDecimation=C.c_uint32.from_address(resampler+0x30).value,
                       lowpass=array_at(u32(4),C.c_int16,u32(0xcc8)),
                       highpass=array_at(u32(8),C.c_int16,u32(0xcc8)),
                       toneFilters=[array_at(u32(12+i*4),C.c_int16,u32(0xccc)) for i in range(12)],
                       sampleThresholds=array_at(address+0x278,C.c_uint32,6),
                       smoothing=array_at(address+0xa7c,C.c_float,72))
            args.out.write_text(json.dumps(value,indent=2)+'\n')
            print(json.dumps({key:value[key] for key in ['octaves','lowpassTaps','toneTaps','startupFrames','resamplerRatio','sampleThresholds']}))
        finally:release(address)
    finally:
        for page in pages:k.VirtualFree(page,0,0x8000)


if __name__=='__main__':main()
