"""Audited chorus-model oracle using generated labels/statistics only.

Runs the isolated original routine with/without observers and compares all
persistent state after excluding the two caller-owned input pointer values.
The observers preserve integer, x87 and SSE state. No music or DLL writes.
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
from synthetic_chorus_input import KINDS,LABELS,COUNTS,inputs
from chorus_observation import POINTS,capture


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True);p.add_argument('--out',type=Path,required=True);args=p.parse_args()
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
    pages=[];protections={};patches=[];callbacks=[];events=[];errors=[];cases=[]
    def allocate(code):
        page=k.VirtualAlloc(None,len(code),0x3000,4)
        if not page:raise C.WinError(C.get_last_error())
        pages.append(page);C.memmove(page,code,len(code));old=C.c_uint32()
        if not k.VirtualProtect(page,len(code),0x20,C.byref(old)):raise C.WinError(C.get_last_error())
        k.FlushInstructionCache(k.GetCurrentProcess(),page,len(code));return page
    # e100: ECX=start frame, EDX=optional headers, stack=(state,length frames).
    body=(b'\x55\x89\xe5\x53\x56\x57\x31\xc9\x31\xd2\xff\x75\x0c\xff\x75\x08\xb8'
          +struct.pack('<I',module+0xe100)+b'\xff\xd0\x5f\x5e\x5b\x89\xec\x5d\xc3')
    summarize=C.CFUNCTYPE(None,C.c_void_p,C.c_uint32)(allocate(body))
    run=C.WINFUNCTYPE(C.c_uint32,C.c_void_p)(module+0x117a0)
    def observer(stage):
        @C.CFUNCTYPE(None,C.c_void_p,C.c_void_p)
        def callback(frame,registers):
            try:events.append(capture(stage,frame,registers))
            except Exception as error:errors.append(str(error))
        callbacks.append(callback);return C.cast(callback,C.c_void_p).value
    def patch(observe):
        for site,original,replacement in patches:
            C.memmove(site,replacement if observe else original,5);k.FlushInstructionCache(k.GetCurrentProcess(),site,5)
    def calculate(times,labels,types,blocks,block_count):
        count=len(times);state=(C.c_uint32*(0xcf8//4))();record=(C.c_uint32*(0x130//4))()
        beats=(C.c_ubyte*(count*168))();buffers=[];headers=[];shapes=[]
        state[0x10c//4]=1;state[0x110//4]=6;state[0x118//4]=1;state[0x114//4]=0x3e022391
        state[0x124//4]=C.addressof(record);record[1]=1;record[2]=297
        state[0x474//4]=C.addressof(beats);state[0x478//4]=count;state[0x48c//4]=types
        for i in range(count):
            C.c_float.from_buffer(beats,i*168).value=times[i];C.c_int32.from_buffer(beats,i*168+164).value=labels[i]
        for column in range(32):
            values=(C.c_float*297)(*[blocks[b*32+column] if b<block_count else 0 for b in range(297)])
            shape=(C.c_uint32*2)(297,0x10);header=(C.c_uint32*5)(C.addressof(values),297,1,C.addressof(shape),0)
            header_column=column%16*2+column//16;record[0xc//4+header_column]=C.addressof(header)
            buffers.append(values);headers.append(header);shapes.append(shape)
        summarize(state,block_count*128);C.memmove(C.addressof(state)+0x15c,C.addressof(state)+0x35c,256)
        before=bytes(beats);status=run(state)&255
        if before!=bytes(beats):raise RuntimeError('Original chorus changed beat data')
        selected=list(struct.unpack('<II',C.string_at(C.addressof(state)+0x490,8)))
        stable=bytearray(bytes(state))
        for offset in [0x124,0x474]:stable[offset:offset+4]=b'\0'*4
        return dict(status=status,selected=selected,stateSHA256=hashlib.sha256(stable).hexdigest())
    try:
        for stage,rva,target,parent_offset in POINTS:
            site=module+rva;original=C.string_at(site,5)
            if original[0]!=0xe8 or site+5+struct.unpack('<i',original[1:])[0]!=module+target:raise ValueError('Audited chorus call differs')
            callback=observer(stage)
            code=(b'\x55\x89\xe5\x60\x81\xec\x10\x02\x00\x00\x83\xe4\xf0'
                  +b'\x0f\xae\x04\x24\x89\xe6\xdb\xe3\x8d\x45\xe0\x50\x8d\x45'
                  +bytes([parent_offset])+b'\x50\xb8'+struct.pack('<I',callback)+b'\xff\xd0\x83\xc4\x08'
                  +b'\x0f\xae\x0e\x8d\x65\xe0\x61\x89\xec\x5d')
            # Reserve a thunk page before computing its relative tail jump.
            page=k.VirtualAlloc(None,len(code)+5,0x3000,4)
            if not page:raise C.WinError(C.get_last_error())
            pages.append(page);code+=b'\xe9'+struct.pack('<I',(module+target-page-len(code)-5)&0xffffffff)
            C.memmove(page,code,len(code));old=C.c_uint32()
            if not k.VirtualProtect(page,len(code),0x20,C.byref(old)):raise C.WinError(C.get_last_error())
            k.FlushInstructionCache(k.GetCurrentProcess(),page,len(code));patches.append((site,original,b'\xe8'+struct.pack('<I',(page-site-5)&0xffffffff)))
            page_start=site&~4095
            if page_start not in protections:
                if not k.VirtualProtect(page_start,4096,0x40,C.byref(old)):raise C.WinError(C.get_last_error())
                protections[page_start]=old.value
        for kind in KINDS:
            for pattern in LABELS:
                for count in COUNTS:
                    times,labels,types,blocks,n=inputs(kind,pattern,count)
                    patch(False);baseline=calculate(times,labels,types,blocks,n);events.clear()
                    patch(True);observed=calculate(times,labels,types,blocks,n)
                    if errors:raise RuntimeError(errors)
                    if observed!=baseline:raise RuntimeError('Observation changed original persistent state')
                    cases.append(dict(kind=kind,pattern=pattern,count=count,types=types,blockCount=n,
                                      selected=observed['selected'],observations=list(events),unobservedVerified=True,
                                      normalizedStateSHA256=observed['stateSHA256']))
        args.out.write_text(json.dumps(dict(schemaVersion=1,dllSHA256=AUDITED_SHA256,analysisVersion='1.6.1',input='self-generated labels, times and weighted statistics',cases=cases),indent=2)+'\n')
        print(json.dumps(dict(cases=len(cases),scoredRuns=sum(sum(e['stage']=='chorus_score' for e in c['observations']) for c in cases))))
    finally:
        if protections:
            patch(False)
            for page,protection in protections.items():ignored=C.c_uint32();k.VirtualProtect(page,4096,protection,C.byref(ignored))
        for page in pages:k.VirtualFree(page,0,0x8000)
        k.FreeLibrary(module)


if __name__=='__main__':main()
