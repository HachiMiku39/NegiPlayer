"""Observe original tempo candidates during a full private PCM analysis.

Redirects one loaded-process free call, records the completed magnitude array
and candidate register, then frees through the original CRT. Restores the call
site in finally. --verify-unobserved checks the complete result is unchanged.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Resources/Enrichment'))
from probe_integer_fir_windows import AUDITED_SHA256
from sensme_analyze_windows import analyse


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True);p.add_argument('--pcm',type=Path,required=True)
    p.add_argument('--out-prefix',type=Path,required=True);p.add_argument('--verify-unobserved',action='store_true')
    args=p.parse_args()
    if C.sizeof(C.c_void_p)!=4 or hashlib.sha256(args.dll.read_bytes()).hexdigest()!=AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and Windows x86 Python')
    k=C.WinDLL('kernel32',use_last_error=True)
    k.LoadLibraryW.argtypes=[C.c_wchar_p];k.LoadLibraryW.restype=C.c_void_p
    k.FreeLibrary.argtypes=[C.c_void_p]
    k.VirtualAlloc.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.c_uint32];k.VirtualAlloc.restype=C.c_void_p
    k.VirtualProtect.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_uint32)]
    k.VirtualFree.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32]
    k.GetCurrentProcess.restype=C.c_void_p;k.FlushInstructionCache.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t]
    module=k.LoadLibraryW(str(args.dll.resolve()))
    if not module:raise C.WinError(C.get_last_error())
    free=C.CFUNCTYPE(None,C.c_void_p)(module+0x28b3d)
    observations=[];errors=[];energy_blocks=bytearray();mono_input=bytearray();configuration={};pcm_partitions=[]
    @C.CFUNCTYPE(None,C.c_void_p,C.c_void_p,C.c_int32,C.c_uint32)
    def observe_pcm(bank,pointer,count,control_word):
        try:
            mono_input.extend(C.string_at(pointer,count*2))
            pcm_partitions.append(count)
            if not configuration:
                def u32(offset):return C.c_uint32.from_address(bank+offset).value
                configuration.update(lowpassTaps=u32(0xcc8),toneTaps=u32(0xccc),startupFrames=u32(0xcd0),
                    x87ControlWord=control_word,
                    ratio=C.c_double.from_address(u32(0xcc0)+8).value,
                    lowpass=list((C.c_int16*u32(0xcc8)).from_address(u32(4))),
                    highpass=list((C.c_int16*u32(0xcc8)).from_address(u32(8))),
                    toneFilters=[list((C.c_int16*u32(0xccc)).from_address(u32(12+tone*4))) for tone in range(12)],
                    smoothing=list((C.c_float*72).from_address(bank+0xa7c)))
        except Exception as e:errors.append(str(e))
    @C.CFUNCTYPE(None,C.c_void_p)
    def observe_energy(pointer):
        try:energy_blocks.extend(C.string_at(pointer,128*72*2))
        except Exception as e:errors.append(str(e))
    @C.CFUNCTYPE(None,C.c_void_p,C.c_int32)
    def observe(pointer,candidate):
        try:
            payload=C.string_at(pointer,2049*4)
            path=Path(str(args.out_prefix)+f'.s{len(observations):02d}.f32le');path.write_bytes(payload)
            observations.append(dict(candidate=candidate,path=str(path),SHA256=hashlib.sha256(payload).hexdigest()))
        except Exception as e:errors.append(str(e))
        finally:free(pointer)
    callback=C.cast(observe,C.c_void_p).value
    # ESI holds the selected candidate; the original call is cdecl free(ptr).
    code=(b'\x55\x89\xe5\x60\x56\xff\x75\x08\xb8'+struct.pack('<I',callback)
          +b'\xff\xd0\x83\xc4\x08\x61\x89\xec\x5d\xc3')
    page=k.VirtualAlloc(None,len(code),0x3000,4)
    if not page:raise C.WinError(C.get_last_error())
    C.memmove(page,code,len(code));old_page=C.c_uint32()
    if not k.VirtualProtect(page,len(code),0x20,C.byref(old_page)):raise C.WinError(C.get_last_error())
    k.FlushInstructionCache(k.GetCurrentProcess(),page,len(code))
    energy_callback=C.cast(observe_energy,C.c_void_p).value
    energy_code=(b'\x55\x89\xe5\x60\xff\x75\x0c\xb8'+struct.pack('<I',energy_callback)
                 +b'\xff\xd0\x83\xc4\x04\x61\xff\x75\x10\xff\x75\x0c\xff\x75\x08\xb8'
                 +struct.pack('<I',module+0xbb20)+b'\xff\xd0\x89\xec\x5d\xc2\x0c\x00')
    energy_page=k.VirtualAlloc(None,len(energy_code),0x3000,4)
    if not energy_page:raise C.WinError(C.get_last_error())
    C.memmove(energy_page,energy_code,len(energy_code));protection=C.c_uint32()
    if not k.VirtualProtect(energy_page,len(energy_code),0x20,C.byref(protection)):raise C.WinError(C.get_last_error())
    k.FlushInstructionCache(k.GetCurrentProcess(),energy_page,len(energy_code))
    energy_site=module+0x5ade;energy_original=C.string_at(energy_site,5)
    if energy_original[0]!=0xe8 or energy_site+5+struct.unpack('<i',energy_original[1:])[0]!=module+0xbb20:
        raise RuntimeError('Audited accumulator call site differs')
    pcm_callback=C.cast(observe_pcm,C.c_void_p).value
    pcm_code=(b'\x55\x89\xe5\x60\x6a\x00\xd9\x3c\x24\xff\x75\x10\xff\x75\x0c\xff\x75\x08\xb8'+struct.pack('<I',pcm_callback)
              +b'\xff\xd0\x83\xc4\x10\x61\xff\x75\x10\xff\x75\x0c\xff\x75\x08\xb8'
              +struct.pack('<I',module+0x25650)+b'\xff\xd0\x89\xec\x5d\xc2\x0c\x00')
    pcm_page=k.VirtualAlloc(None,len(pcm_code),0x3000,4)
    if not pcm_page:raise C.WinError(C.get_last_error())
    C.memmove(pcm_page,pcm_code,len(pcm_code))
    if not k.VirtualProtect(pcm_page,len(pcm_code),0x20,C.byref(protection)):raise C.WinError(C.get_last_error())
    k.FlushInstructionCache(k.GetCurrentProcess(),pcm_page,len(pcm_code))
    pcm_site=module+0x5a3a;pcm_original=C.string_at(pcm_site,5)
    if pcm_original[0]!=0xe8 or pcm_site+5+struct.unpack('<i',pcm_original[1:])[0]!=module+0x25650:
        raise RuntimeError('Audited PCM dispatch call site differs')
    site=module+0xec93;original=C.string_at(site,5)
    if original[0]!=0xe8 or site+5+struct.unpack('<i',original[1:])[0]!=module+0x28b3d:
        raise RuntimeError('Audited tempo observation call site differs')
    previous=C.c_uint32()
    if not k.VirtualProtect(site,5,0x40,C.byref(previous)):raise C.WinError(C.get_last_error())
    energy_previous=C.c_uint32()
    if not k.VirtualProtect(energy_site,5,0x40,C.byref(energy_previous)):raise C.WinError(C.get_last_error())
    # Both dispatch call sites are on the same page. Restore both byte ranges
    # before restoring that page's original protection once.
    if energy_site//4096!=pcm_site//4096:raise RuntimeError('Unexpected dispatch page layout')
    try:
        C.memmove(site,b'\xe8'+struct.pack('<I',(page-site-5)&0xffffffff),5)
        k.FlushInstructionCache(k.GetCurrentProcess(),site,5)
        C.memmove(energy_site,b'\xe8'+struct.pack('<I',(energy_page-energy_site-5)&0xffffffff),5)
        k.FlushInstructionCache(k.GetCurrentProcess(),energy_site,5)
        C.memmove(pcm_site,b'\xe8'+struct.pack('<I',(pcm_page-pcm_site-5)&0xffffffff),5)
        k.FlushInstructionCache(k.GetCurrentProcess(),pcm_site,5)
        blob,summary=analyse(args.dll,args.pcm)
    finally:
        C.memmove(site,original,5);k.FlushInstructionCache(k.GetCurrentProcess(),site,5)
        ignored=C.c_uint32();k.VirtualProtect(site,5,previous.value,C.byref(ignored))
        C.memmove(energy_site,energy_original,5);k.FlushInstructionCache(k.GetCurrentProcess(),energy_site,5)
        C.memmove(pcm_site,pcm_original,5);k.FlushInstructionCache(k.GetCurrentProcess(),pcm_site,5)
        k.VirtualProtect(energy_site,5,energy_previous.value,C.byref(ignored))
        k.VirtualFree(page,0,0x8000)
        k.VirtualFree(energy_page,0,0x8000)
        k.VirtualFree(pcm_page,0,0x8000)
    try:
        if errors:raise RuntimeError(errors)
        if not observations:raise RuntimeError('No tempo candidates observed')
        report=dict(dllSHA256=AUDITED_SHA256,pcmSHA256=hashlib.sha256(args.pcm.read_bytes()).hexdigest(),
                    observedResultSHA256=hashlib.sha256(blob).hexdigest(),summary=summary,segments=observations)
        energy_path=Path(str(args.out_prefix)+'.energy.u16le');energy_path.write_bytes(energy_blocks)
        report.update(energyBlocksPath=str(energy_path),energyBlockCount=len(energy_blocks)//(128*144),energySHA256=hashlib.sha256(energy_blocks).hexdigest())
        mono_path=Path(str(args.out_prefix)+'.mono.s16le');mono_path.write_bytes(mono_input)
        report.update(monoInputPath=str(mono_path),monoInputSHA256=hashlib.sha256(mono_input).hexdigest(),pcmPartitions=pcm_partitions,configuration=configuration)
        if args.verify_unobserved:
            plain,_=analyse(args.dll,args.pcm)
            report['unobservedResultSHA256']=hashlib.sha256(plain).hexdigest()
            if plain!=blob:raise RuntimeError('Observation changed the full analysis result')
        Path(str(args.out_prefix)+'.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(dict(segments=len(observations),candidates=[x['candidate'] for x in observations],unobservedVerified=args.verify_unobserved)))
    finally:k.FreeLibrary(module)


if __name__=='__main__':main()
