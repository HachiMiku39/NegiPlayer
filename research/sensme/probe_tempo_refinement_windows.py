"""Observe tempo refinement at audited call boundaries in a private process.

Preserves all integer, x87 and SSE registers around observation callbacks,
then tail-calls the original routine. Input PCM and the DLL file are read-only.
The full result must match a previously verified unobserved analysis of the
same PCM and DLL. Captured frames and derived audio data stay at --out-prefix.
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
from synthetic_tempo_input import make as synthetic_input
from synthetic_tonal_input import KINDS as TONAL_KINDS,make as synthetic_tones
from chorus_observation import POINTS as CHORUS_POINTS,capture as capture_chorus


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll',type=Path,required=True);parser.add_argument('--pcm',type=Path,required=True)
    parser.add_argument('--reference',type=Path);parser.add_argument('--out-prefix',type=Path,required=True)
    parser.add_argument('--synthetic-case',type=int,choices=range(4),help='Inject self-generated stage inputs; compare observation with injection-only baseline')
    parser.add_argument('--synthetic-tone-kind',choices=TONAL_KINDS,help='Also inject generated compressed tone groups (requires --synthetic-case)')
    args=parser.parse_args()
    if args.synthetic_tone_kind is not None and args.synthetic_case is None:parser.error('--synthetic-tone-kind requires --synthetic-case')
    if C.sizeof(C.c_void_p)!=4 or hashlib.sha256(args.dll.read_bytes()).hexdigest()!=AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and Windows x86 Python')
    pcm_digest=hashlib.sha256(args.pcm.read_bytes()).hexdigest();reference=None
    if args.synthetic_case is None:
        if not args.reference:parser.error('--reference is required outside synthetic mode')
        reference=json.loads(args.reference.read_text())
        if pcm_digest!=reference['pcmSHA256'] or reference['dllSHA256']!=AUDITED_SHA256:raise ValueError('Reference input differs')
        if reference.get('unobservedResultSHA256')!=reference['observedResultSHA256']:raise ValueError('Reference has no verified unobserved result')
    k=C.WinDLL('kernel32',use_last_error=True)
    k.LoadLibraryW.argtypes=[C.c_wchar_p];k.LoadLibraryW.restype=C.c_void_p
    k.FreeLibrary.argtypes=[C.c_void_p]
    k.VirtualAlloc.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.c_uint32];k.VirtualAlloc.restype=C.c_void_p
    k.VirtualProtect.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_uint32)]
    k.VirtualFree.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32]
    k.GetCurrentProcess.restype=C.c_void_p;k.FlushInstructionCache.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t]
    module=k.LoadLibraryW(str(args.dll.resolve()))
    if not module:raise C.WinError(C.get_last_error())
    # Parent ESP before arguments, corresponding to the audited stack layout.
    points=[('vote_period',0xef7c,0x305b4,8),('refined_period',0xf252,0x305b4,8),
            ('first_phase',0xf397,0x305b4,8),
            ('final_phase',0xf7ed,0x308ca,8),('grid_allocation',0xf844,0x28b42,12),
            ('grid_candidates',0xfa55,0x28b3d,12),('grid_final',0xaeb1,0xfe20,8),
            ('self_similarity_ready',0xaeb7,0x10f10,8),('coarse_sections',0xaebd,0x117a0,8),
            ('refined_sections',0xaee2,0x132e0,8),('section_keys_ready',0xaf03,0x13730,8)]+CHORUS_POINTS
    if args.synthetic_case is not None:points.insert(0,('synthetic_input',0xedbb,0x28b42,12))
    pages=[];patches=[];protections={};callbacks=[];observations=[];errors=[]
    observer_type=C.CFUNCTYPE(None,C.c_void_p,C.c_void_p,C.c_void_p);synthetic_metadata={}
    def observer(stage):
        @observer_type
        def capture(frame_address,fp_address,register_address):
            try:
                if stage.startswith('chorus_'):
                    observations.append(capture_chorus(stage,frame_address,register_address));return
                if stage in ['grid_final','self_similarity_ready','coarse_sections','refined_sections','section_keys_ready']:
                    if stage=='section_keys_ready':
                        registers=struct.unpack('<8I',C.string_at(register_address,32))
                        state_address=C.c_uint32.from_address(registers[1]+0xc).value
                    else:state_address=C.c_uint32.from_address(frame_address).value
                    state=C.string_at(state_address,0xcf8)
                    pointer,count=struct.unpack_from('<II',state,0x474)
                    if not pointer or not 0<count<=960:raise ValueError('Invalid completed beat array')
                    prefix=str(args.out_prefix)+f'.{len(observations):02d}-{stage}'
                    path=Path(prefix+'.beats.bin');path.write_bytes(C.string_at(pointer,count*0xa8))
                    state_path=Path(prefix+'.state.bin');state_path.write_bytes(state)
                    entry=dict(stage=stage,beatsPath=str(path),statePath=str(state_path),count=count)
                    if stage=='self_similarity_ready':
                        size=struct.unpack_from('<I',state,0x480)[0]-1
                        matrix=struct.unpack_from('<I',state,0x488)[0]
                        if not matrix or not 0<size<960:raise ValueError('Invalid self similarity matrix')
                        payload=C.string_at(matrix,size*size*2);matrix_path=Path(prefix+'.matrix.u16le');matrix_path.write_bytes(payload)
                        record=struct.unpack_from('<I',state,0x124)[0]
                        tones=C.c_uint32.from_address(record+0x11c).value
                        tonal_payload=C.string_at(tones,19008*12*2);tonal_path=Path(prefix+'.tones.u16le');tonal_path.write_bytes(tonal_payload)
                        entry.update(matrixSide=size,matrixPath=str(matrix_path),matrixSHA256=hashlib.sha256(payload).hexdigest(),
                                     compressedTonesPath=str(tonal_path),compressedTonesSHA256=hashlib.sha256(tonal_payload).hexdigest())
                    observations.append(entry)
                    return
                frame=C.string_at(frame_address,0x8d0)
                def u32(offset):return struct.unpack_from('<I',frame,offset)[0]
                state_address=u32(0x8cc);state=C.string_at(state_address,0xcf8)
                def state_u32(offset):return struct.unpack_from('<I',state,offset)[0]
                if stage=='synthetic_input':
                    count=u32(0x40);segments=u32(0x30)
                    candidates,onsets,stats=synthetic_input(args.synthetic_case,count,segments)
                    C.memmove(frame_address+0xdc,(C.c_int32*len(candidates))(*candidates),len(candidates)*4)
                    record=state_u32(0x124)
                    for band in range(3):
                        pointer=C.c_uint32.from_address(record+0x124+band*4).value
                        C.memmove(pointer,(C.c_float*count).from_buffer(onsets,band*count*4),count*4)
                    blocks=count//128
                    for column in range(32):
                        # Record headers are interleaved mean/std per stream;
                        # synthetic block rows store all means, then all stds.
                        header_column=(column%16)*2+column//16
                        header=C.c_uint32.from_address(record+0xc+header_column*4).value
                        pointer=C.c_uint32.from_address(header).value
                        C.memmove(pointer,(C.c_float*blocks)(*[stats[block*32+column] for block in range(blocks)]),blocks*4)
                    synthetic_metadata.update(case=args.synthetic_case,frames=count,segments=segments,candidates=candidates,
                                              onsetsSHA256=hashlib.sha256(onsets.tobytes()).hexdigest(),statsSHA256=hashlib.sha256(stats.tobytes()).hexdigest())
                    if args.synthetic_tone_kind is not None:
                        groups=synthetic_tones(args.synthetic_tone_kind)
                        for group in range(2):
                            pointer=C.c_uint32.from_address(record+0x110+group*4).value
                            C.memmove(pointer,(C.c_uint16*len(groups[group])).from_buffer(groups[group]),len(groups[group])*2)
                        synthetic_metadata.update(toneKind=args.synthetic_tone_kind,
                                                  toneSHA256=[hashlib.sha256(group.tobytes()).hexdigest() for group in groups])
                    return
                prefix=str(args.out_prefix)+f'.{len(observations):02d}-{stage}'
                def save(suffix,payload):
                    path=Path(prefix+suffix);path.write_bytes(payload);return str(path)
                record=dict(stage=stage,framePath=save('.stack.bin',frame),statePath=save('.state.bin',state),
                            fpPath=save('.fp.bin',C.string_at(fp_address,512)),
                            registers=list(struct.unpack('<8I',C.string_at(register_address,32))),
                            candidate=u32(0x18),segmentCount=u32(0x30),frames=u32(0x40),
                            scalarWords={hex(offset):state_u32(offset) for offset in [0x114,0x468,0x46c,0x470,0x478]})
                count=u32(0x40);pointer=u32(0x20)
                if pointer and 0<count<=38016:
                    payload=C.string_at(pointer,count*4)
                    record.update(weightedOnsetsPath=save('.weighted.f32le',payload),weightedOnsetsSHA256=hashlib.sha256(payload).hexdigest())
                if stage=='grid_candidates':
                    count=state_u32(0x478);pointer=state_u32(0x474)
                    if pointer and 0<count<=10000:record['beatsPath']=save('.beats.bin',C.string_at(pointer,count*0xa8))
                observations.append(record)
            except Exception as error:errors.append(str(error))
        callbacks.append(capture);return C.cast(capture,C.c_void_p).value
    try:
        for stage,rva,target,parent_offset in points:
            site=module+rva;original=C.string_at(site,5)
            if original[0]!=0xe8 or site+5+struct.unpack('<i',original[1:])[0]!=module+target:
                raise RuntimeError(f'Audited {stage} call site differs')
            callback=observer(stage)
            # Save GPRs; align a 512-byte FXSAVE area. FNINIT gives Python an
            # empty x87 stack. FXRSTOR restores the live original stack before
            # tail-calling the original helper, including its control word.
            code=(b'\x55\x89\xe5\x60\x81\xec\x10\x02\x00\x00\x83\xe4\xf0'
                  +b'\x0f\xae\x04\x24\x89\xe6\xdb\xe3\x8d\x45\xe0\x50\x56'
                  +b'\x8d\x45'+bytes([parent_offset])+b'\x50\xb8'+struct.pack('<I',callback)
                  +b'\xff\xd0\x83\xc4\x0c\x0f\xae\x0e\x8d\x65\xe0\x61\x89\xec\x5d')
            page=k.VirtualAlloc(None,len(code)+5,0x3000,4)
            if not page:raise C.WinError(C.get_last_error())
            pages.append(page);code+=b'\xe9'+struct.pack('<I',(module+target-page-len(code)-5)&0xffffffff)
            C.memmove(page,code,len(code));old=C.c_uint32()
            if not k.VirtualProtect(page,len(code),0x20,C.byref(old)):raise C.WinError(C.get_last_error())
            k.FlushInstructionCache(k.GetCurrentProcess(),page,len(code))
            patches.append((stage,site,original,b'\xe8'+struct.pack('<I',(page-site-5)&0xffffffff)))
        for _,site,_,_ in patches:
            page=site&~4095
            if page not in protections:
                old=C.c_uint32()
                if not k.VirtualProtect(page,4096,0x40,C.byref(old)):raise C.WinError(C.get_last_error())
                protections[page]=old.value
        try:
            if args.synthetic_case is not None:
                for stage,site,_,replacement in patches:
                    if stage=='synthetic_input':C.memmove(site,replacement,5);k.FlushInstructionCache(k.GetCurrentProcess(),site,5)
                baseline,_=analyse(args.dll,args.pcm)
                if errors:raise RuntimeError(errors)
            for _,site,_,replacement in patches:
                C.memmove(site,replacement,5);k.FlushInstructionCache(k.GetCurrentProcess(),site,5)
            blob,summary=analyse(args.dll,args.pcm)
        finally:
            for _,site,original,_ in patches:
                C.memmove(site,original,5);k.FlushInstructionCache(k.GetCurrentProcess(),site,5)
            for page,protection in protections.items():
                ignored=C.c_uint32();k.VirtualProtect(page,4096,protection,C.byref(ignored))
            protections.clear()
        if errors:raise RuntimeError(errors)
        result_digest=hashlib.sha256(blob).hexdigest()
        expected=hashlib.sha256(baseline).hexdigest() if args.synthetic_case is not None else reference['unobservedResultSHA256']
        if result_digest!=expected:raise RuntimeError('Observation changed full analysis result')
        optional={'vote_period','synthetic_input',*[p[0] for p in CHORUS_POINTS]}
        if not all(any(o['stage']==name for o in observations) for name,_,_,_ in points if name not in optional):
            raise RuntimeError('Not all refinement stages were observed')
        report=dict(dllSHA256=AUDITED_SHA256,pcmSHA256=pcm_digest,resultSHA256=result_digest,
                    unobservedVerified=True,summary=summary,observations=observations)
        if synthetic_metadata:report['syntheticInput']=synthetic_metadata
        Path(str(args.out_prefix)+'.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(dict(stages=[o['stage'] for o in observations],unobservedVerified=True)))
    finally:
        for page,protection in protections.items():
            ignored=C.c_uint32();k.VirtualProtect(page,4096,protection,C.byref(ignored))
        for page in pages:k.VirtualFree(page,0,0x8000)
        k.FreeLibrary(module)


if __name__=='__main__':main()
