"""Observe 128-frame spectral statistics from private, audited energy frames.

Only an isolated loaded module's single call site is temporarily redirected to
copy each intermediate series before invoking the original mean routine. The
DLL file and input frames are read-only. All outputs stay local to --out-prefix.
"""
import argparse
import array
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
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--features',type=Path,required=True)
    p.add_argument('--out-prefix',type=Path,required=True)
    p.add_argument('--skip-frames',type=int,default=292)
    p.add_argument('--max-blocks',type=int,default=297)
    p.add_argument('--no-series',action='store_true',help='Run original summary path without the observation call-site patch')
    args=p.parse_args()
    if args.skip_frames<0 or args.max_blocks<1:p.error('Invalid frame range')
    if C.sizeof(C.c_void_p)!=4 or hashlib.sha256(args.dll.read_bytes()).hexdigest()!=AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and Windows x86 Python')
    raw=args.features.read_bytes()
    if len(raw)%144:raise ValueError('Expected 72-column uint16 energy frames')
    values=array.array('H');values.frombytes(raw)
    if sys.byteorder!='little':values.byteswap()
    block_count=min(args.max_blocks,max(0,(len(raw)//144-args.skip_frames)//128))
    if not block_count:raise ValueError('No complete post-startup statistics blocks')
    k=C.WinDLL('kernel32',use_last_error=True)
    k.LoadLibraryW.argtypes=[C.c_wchar_p];k.LoadLibraryW.restype=C.c_void_p
    k.VirtualAlloc.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.c_uint32];k.VirtualAlloc.restype=C.c_void_p
    k.VirtualProtect.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_uint32)]
    k.VirtualFree.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32]
    k.GetCurrentProcess.restype=C.c_void_p
    k.FlushInstructionCache.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t]
    module=k.LoadLibraryW(str(args.dll.resolve()))
    if not module:raise C.WinError(C.get_last_error())
    pages=[];series_file=None;copies=0;errors=[]
    def thunk(code,prototype):
        page=k.VirtualAlloc(None,len(code),0x3000,4)
        if not page:raise C.WinError(C.get_last_error())
        pages.append(page);C.memmove(page,code,len(code));old=C.c_uint32()
        if not k.VirtualProtect(page,len(code),0x20,C.byref(old)):raise C.WinError(C.get_last_error())
        k.FlushInstructionCache(k.GetCurrentProcess(),page,len(code))
        return prototype(page)
    def esi_call(rva):
        code=(b'\x55\x89\xe5\x56\x8b\x75\x08\xb8'+struct.pack('<I',module+rva)
              +b'\xff\xd0\x5e\x89\xec\x5d\xc3')
        return thunk(code,C.CFUNCTYPE(None,C.c_void_p))
    ctor=(b'\x55\x89\xe5\x8b\x45\x08\xb9'+struct.pack('<I',6)
          +b'\xff\x75\x0c\xba'+struct.pack('<I',module+0xc360)
          +b'\xff\xd2\x89\xec\x5d\xc3')
    mean_type=C.WINFUNCTYPE(None,C.c_void_p,C.c_void_p,C.c_int32)
    original_mean=mean_type(module+0x15ff0)
    original_deviation=mean_type(module+0x162a0)
    dll_free=C.CFUNCTYPE(None,C.c_void_p)(module+0x28b3d)
    @mean_type
    def capture(input_array,output_array,dimension):
        nonlocal copies
        try:
            header=(C.c_uint32*5).from_address(input_array)
            if header[1]!=128 or header[2]!=1 or not header[0]:
                errors.append('Unexpected intermediate array shape')
            else:
                series_file.write(C.string_at(header[0],128*4));copies+=1
        except Exception as error:errors.append(str(error))
        original_mean(input_array,output_array,dimension)
    site=module+0xe01e;original=C.string_at(site,5)
    if original[0]!=0xe8 or site+5+struct.unpack('<i',original[1:])[0]!=module+0x15ff0:
        raise RuntimeError('Audited statistics call site differs')
    callback=C.cast(capture,C.c_void_p).value
    replacement=b'\xe8'+struct.pack('<I',(callback-site-5)&0xffffffff)
    previous=C.c_uint32()
    if not k.VirtualProtect(site,5,0x40,C.byref(previous)):raise C.WinError(C.get_last_error())
    try:
        if not args.no_series:
            C.memmove(site,replacement,5);k.FlushInstructionCache(k.GetCurrentProcess(),site,5)
        construct=thunk(ctor,C.CFUNCTYPE(None,C.c_void_p,C.c_int32))
        initialize=esi_call(0xc4c0);release=esi_call(0xc9f0)
        run=C.WINFUNCTYPE(C.c_uint32,C.c_void_p,C.c_void_p,C.c_void_p,C.c_int32,C.c_int32,
                         C.c_int32,C.c_void_p,C.c_void_p,C.c_void_p)(module+0xcf60)
        report=dict(schemaVersion=1,dllSHA256=AUDITED_SHA256,inputSHA256=hashlib.sha256(raw).hexdigest(),
                    skippedFrames=args.skip_frames,blocks=block_count,profiles=[])
        for mode in [1,0]:
            profile=(C.c_ubyte*0xe8)();address=C.addressof(profile)
            construct(address,mode);initialize(address)
            def u32(offset):return C.c_uint32.from_address(address+offset).value
            prefix=str(args.out_prefix)+'.profile-'+str(mode)
            series_path=Path(prefix+'.series.f32le');summary_path=Path(prefix+'.summary.f32le')
            params=dict(mode=mode,scalarWords=list((C.c_uint32*33).from_address(address)),
                        lowerBandBoundary=u32(0x90),upperBandBoundary=u32(0x94),
                        weights={hex(offset):list((C.c_float*72).from_address(u32(offset)))
                                 for offset in [0x84,0x98,0xa4,0xb0,0xbc,0xc8]})
            try:
                copies=0
                with series_path.open('wb') as output,summary_path.open('wb') as summaries:
                    series_file=output
                    for block in range(block_count):
                        at=(args.skip_frames+block*128)*144
                        frames=(C.c_uint16*(128*72)).from_buffer(values,at)
                        means=(C.c_float*16)();deviations=(C.c_float*16)()
                        result=run(None,None,frames,72,1,128,means,deviations,address)
                        if result&255!=1:raise RuntimeError('Statistics routine failed')
                        summaries.write(bytes(means)+bytes(deviations))
                    series_file=None
                if (not args.no_series and copies!=block_count*16) or errors:raise RuntimeError((copies,errors))
                params.update(blocks=block_count,seriesPath=str(series_path),summaryPath=str(summary_path),
                              seriesSHA256=hashlib.sha256(series_path.read_bytes()).hexdigest(),
                              summarySHA256=hashlib.sha256(summary_path.read_bytes()).hexdigest())
                summaries=array.array('f');summaries.frombytes(summary_path.read_bytes())
                aggregate=(C.c_float*64)();output_array=(C.c_uint32*5)(0,0,0,0,0xffffffff)
                try:
                    for column in range(32):
                        data=(C.c_float*block_count)(*[summaries[b*32+column] for b in range(block_count)])
                        shape=(C.c_int32*2)(block_count,0x10)
                        input_array=(C.c_uint32*5)(C.addressof(data),block_count,1,C.addressof(shape),0)
                        offset=column if column<16 else column+16
                        original_mean(input_array,output_array,0)
                        aggregate[offset]=C.c_float.from_address(output_array[0]).value
                        original_deviation(input_array,output_array,0)
                        aggregate[offset+16]=C.c_float.from_address(output_array[0]).value
                finally:
                    if output_array[0]:dll_free(output_array[0])
                    if output_array[3]:dll_free(output_array[3])
                aggregate_path=Path(prefix+'.track-summary.f32le');aggregate_path.write_bytes(bytes(aggregate))
                params.update(trackSummaryPath=str(aggregate_path),trackSummarySHA256=hashlib.sha256(bytes(aggregate)).hexdigest())
                report['profiles'].append(params)
            finally:release(address)
        Path(str(args.out_prefix)+'.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(dict(blocks=block_count,profiles=len(report['profiles']),streamsPerBlock=16)))
    finally:
        C.memmove(site,original,5);k.FlushInstructionCache(k.GetCurrentProcess(),site,5)
        ignored=C.c_uint32();k.VirtualProtect(site,5,previous.value,C.byref(ignored))
        for page in pages:k.VirtualFree(page,0,0x8000)


if __name__=='__main__':main()
