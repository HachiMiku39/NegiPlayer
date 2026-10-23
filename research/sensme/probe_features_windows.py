"""Raw energy-frame oracle for the audited bank; synthetic or local mono PCM."""
import array
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from probe_integer_fir_windows import AUDITED_SHA256, signed_word


def feature_input(kind, count):
    state=0x39C0FFEE; result=[]
    for i in range(count):
        state=(1664525*state+1013904223)&0xffffffff
        if kind=='random':value=signed_word(state>>16)
        elif kind=='impulse':value=-32768 if i==0 else 0
        elif kind=='silence':value=0
        elif kind=='limits':value=[-32768,32767,-1,0,1][i%5]
        else:raise ValueError(kind)
        result.append(value)
    return result


def feature_partitions(count, block_frames=0):
    if block_frames:
        for at in range(0,count,block_frames):yield at,min(block_frames,count-at)
        return
    pattern=[1,3,7,13,4096,1,5,127];at=0;i=0
    while at<count:
        size=min(pattern[i%len(pattern)],count-at)
        yield at,size
        at+=size;i+=1


def synthetic_tones():
    state=0x39FA1234;result=[]
    for tone in range(12):
        row=[]
        for tap in range(47):
            state=(1664525*state+1013904223)&0xffffffff
            value=int(signed_word(state>>16)/16)
            if tap==23:value+=12000
            row.append(value)
        result.append(row)
    return result


def load_mono_pcm(path):
    data=path.read_bytes()
    if not data or len(data)%2:raise ValueError('Expected complete nonempty mono s16le PCM')
    samples=array.array('h');samples.frombytes(data)
    if sys.byteorder!='little':samples.byteswap()
    return samples,hashlib.sha256(data).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--frames',type=int,default=262144)
    p.add_argument('--block-frames',type=int,default=0,choices=[0,4096])
    p.add_argument('--synthetic-tones',action='store_true',help='Replace tone taps with self-generated test parameters')
    p.add_argument('--pcm',type=Path,help='Full local mono s16le PCM; use this instead of synthetic input')
    p.add_argument('--frames-out',type=Path,help='Optional private raw uint16 feature frames, with --pcm only')
    args=p.parse_args()
    if args.frames_out and not args.pcm:p.error('--frames-out requires --pcm')
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
    ctor=(b'\x55\x89\xe5\xb9'+struct.pack('<I',256)+b'\xba'+struct.pack('<I',47)
          +b'\xff\x75\x10\xff\x75\x0c\xff\x75\x08\xb8'+struct.pack('<I',module+0x24d70)
          +b'\xff\xd0\x89\xec\x5d\xc3')
    destroy=(b'\x55\x89\xe5\x8b\x4d\x08\x6a\x00\xb8'+struct.pack('<I',module+0x25560)
             +b'\xff\xd0\x89\xec\x5d\xc3')
    try:
        create=thunk(ctor,C.CFUNCTYPE(C.c_void_p,C.c_void_p,C.c_uint32,C.c_uint32))
        control_word=thunk(b'\x6a\x00\xd9\x3c\x24\x58\xc3',C.CFUNCTYPE(C.c_uint32))
        release=thunk(destroy,C.CFUNCTYPE(None,C.c_void_p))
        write=C.WINFUNCTYPE(None,C.c_void_p,C.c_void_p,C.c_int32)(module+0x25650)
        read=C.WINFUNCTYPE(C.c_int32,C.c_void_p,C.c_void_p)(module+0x259c0)
        cases=[]
        for kind in (['pcm'] if args.pcm else ['random','impulse','silence','limits']):
            obj=(C.c_ubyte*0xcd4)();address=C.addressof(obj)
            if create(address,44100,6)!=address:raise RuntimeError('Constructor failed')
            def u32(offset):return C.c_uint32.from_address(address+offset).value
            raw_output=None
            try:
                if args.synthetic_tones:
                    taps=synthetic_tones()
                    for level in range(6):
                        for tone in range(12):
                            fir=u32(0x2fc+(level*12+tone)*4)
                            table=C.c_uint32.from_address(fir).value
                            if table==module+0x3a00c:
                                coefficients=C.c_uint32.from_address(fir+0x18).value
                                words=48
                            elif table==module+0x3a018:
                                coefficients=C.c_uint32.from_address(fir+4).value
                                words=47
                            else:raise RuntimeError('Unexpected tone FIR variant')
                            values=(C.c_int16*words)(*taps[tone])
                            C.memmove(coefficients,values,C.sizeof(values))
                if args.pcm:samples,pcm_hash=load_mono_pcm(args.pcm)
                else:samples=feature_input(kind,args.frames)
                if args.frames_out:raw_output=args.frames_out.open('wb')
                digest=hashlib.sha256();post=hashlib.sha256();frames=0;nonzero=-1
                startup=u32(0xcd0)
                for at,count in feature_partitions(len(samples),args.block_frames):
                    source=((C.c_int16*count).from_buffer(samples,at*2) if isinstance(samples,array.array)
                            else (C.c_int16*count)(*samples[at:at+count]))
                    write(address,source,count)
                    while True:
                        queue=u32(0x50c)
                        available=C.c_uint32.from_address(queue+8).value-C.c_uint32.from_address(queue+12).value
                        if available<0:available+=C.c_uint32.from_address(queue+16).value
                        if not available*2+u32(0xcbc):break
                        out=(C.c_uint16*72)()
                        if read(address,out)&255!=1:raise RuntimeError('Read failed')
                        payload=bytes(out);digest.update(payload)
                        if raw_output:raw_output.write(payload)
                        if frames>=startup:post.update(payload)
                        if nonzero<0 and any(out):nonzero=frames
                        frames+=1
                cases.append(dict(kind=kind,inputFrames=len(samples),rawFrames=frames,startupFrames=startup,
                                  x87ControlWord=control_word(),
                                  blockFrames=args.block_frames,
                                  sha256=digest.hexdigest(),postStartupSHA256=post.hexdigest(),firstNonzero=nonzero))
                if args.pcm:cases[-1]['pcmSHA256']=pcm_hash
            finally:
                if raw_output:raw_output.close()
                release(address)
        args.out.write_text(json.dumps(dict(schemaVersion=1,dllSHA256=AUDITED_SHA256,
            toneSource='synthetic' if args.synthetic_tones else 'audited-default',cases=cases),indent=2)+'\n')
        print(json.dumps(dict(cases=len(cases),rawFrames=[x['rawFrames'] for x in cases])))
    finally:
        for page in pages:k.VirtualFree(page,0,0x8000)


if __name__=='__main__':main()
