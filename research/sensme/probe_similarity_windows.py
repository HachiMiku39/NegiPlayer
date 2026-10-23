"""Self-similarity oracle using generated tone groups and beat times only.

Observes the descriptor array in a private process. All integer/x87/SSE state
is preserved. Each matrix must match a separate run without the observer.
The audited on-disk DLL remains unmodified.
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
from synthetic_similarity_input import KINDS,COUNTS,inputs


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True);p.add_argument('--out-prefix',type=Path,required=True);args=p.parse_args()
    if C.sizeof(C.c_void_p)!=4 or hashlib.sha256(args.dll.read_bytes()).hexdigest()!=AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and Windows x86 Python')
    k=C.WinDLL('kernel32',use_last_error=True)
    k.LoadLibraryW.argtypes=[C.c_wchar_p];k.LoadLibraryW.restype=C.c_void_p;k.FreeLibrary.argtypes=[C.c_void_p]
    k.VirtualAlloc.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.c_uint32];k.VirtualAlloc.restype=C.c_void_p
    k.VirtualProtect.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_uint32)]
    k.VirtualFree.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32];k.GetCurrentProcess.restype=C.c_void_p
    k.FlushInstructionCache.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t]
    module=k.LoadLibraryW(str(args.dll.resolve()))
    if not module:raise C.WinError(C.get_last_error())
    run=C.WINFUNCTYPE(C.c_uint32,C.c_void_p)(module+0xfe20);free=C.CFUNCTYPE(None,C.c_void_p)(module+0x28b3d)
    captures=[];errors=[]
    @C.CFUNCTYPE(None,C.c_void_p)
    def observer(registers_address):
        try:
            registers=struct.unpack('<8I',C.string_at(registers_address,32));header=registers[4]
            pointer,count=struct.unpack('<II',C.string_at(header,8))
            if not pointer or not 12<=count<=5760 or count%12:raise ValueError('Invalid descriptor header')
            captures.append(C.string_at(pointer,count*4))
        except Exception as error:errors.append(str(error))
    code=(b'\x55\x89\xe5\x60\x81\xec\x10\x02\x00\x00\x83\xe4\xf0'
          +b'\x0f\xae\x04\x24\x89\xe6\xdb\xe3\x8d\x45\xe0\x50\xb8'
          +struct.pack('<I',C.cast(observer,C.c_void_p).value)+b'\xff\xd0\x83\xc4\x04'
          +b'\x0f\xae\x0e\x8d\x65\xe0\x61\x89\xec\x5d')
    site=module+0x10279;original=C.string_at(site,5);page=None;old_protection=None;cases=[]
    if original[0]!=0xe8 or site+5+struct.unpack('<i',original[1:])[0]!=module+0x28b42:raise ValueError('Audited descriptor call differs')
    def patch(payload):C.memmove(site,payload,5);k.FlushInstructionCache(k.GetCurrentProcess(),site,5)
    def calculate(tones,times):
        count=len(times);tone_buffer=(C.c_uint16*len(tones)).from_buffer(tones);beats=(C.c_ubyte*(count*168))()
        state=(C.c_uint32*(0x500//4))();record=(C.c_uint32*(0x130//4))()
        state[0x11c//4]=38016;state[0x114//4]=0x3e022391;state[0x124//4]=C.addressof(record)
        state[0x474//4]=C.addressof(beats);state[0x478//4]=count;state[0x47c//4]=2
        record[0x118//4]=1;record[0x11c//4]=C.addressof(tone_buffer)
        for i,t in enumerate(times):C.c_float.from_buffer(beats,i*168).value=t
        try:
            if run(state)&255!=1 or state[0x480//4]!=count//2:raise RuntimeError('Original similarity function failed')
            return C.string_at(state[0x488//4],(count//2-1)**2*2)
        finally:
            free(state[0x488//4]);free(state[0x484//4])
    try:
        page=k.VirtualAlloc(None,len(code)+5,0x3000,4)
        if not page:raise C.WinError(C.get_last_error())
        code+=b'\xe9'+struct.pack('<I',(module+0x28b42-page-len(code)-5)&0xffffffff)
        C.memmove(page,code,len(code));old=C.c_uint32()
        if not k.VirtualProtect(page,len(code),0x20,C.byref(old)):raise C.WinError(C.get_last_error())
        k.FlushInstructionCache(k.GetCurrentProcess(),page,len(code))
        if not k.VirtualProtect(site&~4095,4096,0x40,C.byref(old)):raise C.WinError(C.get_last_error())
        old_protection=old.value;replacement=b'\xe8'+struct.pack('<I',(page-site-5)&0xffffffff)
        for kind in KINDS:
            for count in COUNTS:
                tones,times=inputs(kind,count);patch(original);baseline=calculate(tones,times)
                captures.clear();patch(replacement);matrix=calculate(tones,times)
                if errors:raise RuntimeError(errors)
                if len(captures)!=1 or matrix!=baseline:raise RuntimeError('Observation changed original output')
                prefix=str(args.out_prefix)+f'.{len(cases):02d}';matrix_path=Path(prefix+'.matrix.bin');matrix_path.write_bytes(matrix)
                vector_path=Path(prefix+'.vectors.bin');vector_path.write_bytes(captures[0])
                cases.append(dict(kind=kind,count=count,matrixPath=str(matrix_path),matrixSHA256=hashlib.sha256(matrix).hexdigest(),
                                  vectorsPath=str(vector_path),vectorsSHA256=hashlib.sha256(captures[0]).hexdigest(),unobservedVerified=True))
                print(json.dumps(dict(kind=kind,beats=count)),flush=True)
        Path(str(args.out_prefix)+'.json').write_text(json.dumps(dict(schemaVersion=1,input='self-generated compressed tones and beat timestamps',cases=cases),indent=2)+'\n')
    finally:
        if old_protection is not None:
            patch(original);ignored=C.c_uint32();k.VirtualProtect(site&~4095,4096,old_protection,C.byref(ignored))
        if page:k.VirtualFree(page,0,0x8000)
        k.FreeLibrary(module)


if __name__=='__main__':main()
