"""Compare native default chorus selection and every observed scalar."""
import argparse
import array
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from check_native_spectral_stats import local_path
from synthetic_chorus_input import inputs


class Selection(C.Structure):
    _fields_=[('section_type',C.c_int32),('beat_index',C.c_uint32),('scored_runs',C.c_uint32)]


class Run(C.Structure):
    _fields_=[('start_beat',C.c_uint32),('end_beat',C.c_uint32),('section_type',C.c_int32)]+[
        (name,C.c_float) for name in ['frequency','mean_position','mean_duration','raw_score','probability']]


def check(lib,times,labels,types,blocks,block_count,expected,events):
    count=len(times);scores=(C.c_float*types)();runs=(Run*count)();selection=Selection()
    if not lib.negi_sensme_chorus_select((C.c_float*count)(*times),(C.c_int32*count)(*labels),count,types,
            (C.c_float*len(blocks))(*blocks),block_count,C.byref(selection),scores,runs):raise RuntimeError('Native chorus selection failed')
    differences=[]
    if [selection.section_type,selection.beat_index]!=expected: differences.append(dict(field='selection',native=[selection.section_type,selection.beat_index],reference=expected))
    pre=[e for e in events if e['stage']=='chorus_score'];post=[e for e in events if e['stage']=='chorus_probability']
    totals=[e for e in events if e['stage']=='chorus_totals']
    if events:
        if selection.scored_runs!=len(pre) or len(pre)!=len(post):differences.append(dict(field='scoredRunCount',native=selection.scored_runs,reference=[len(pre),len(post)]))
        def bits(value):return struct.unpack('<I',struct.pack('<f',value))[0]
        for i,(before,after) in enumerate(zip(pre,post)):
            output=runs[i]
            expected_fields=dict(start_beat=before['startBeat'],end_beat=before['endBeat'],section_type=before['sectionType'],
                frequency=before['frequencyBits'],mean_position=before['meanPositionBits'],mean_duration=before['meanDurationBits'],
                raw_score=before['rawScoreBits'],probability=after['probabilityBits'])
            for name,reference in expected_fields.items():
                value=getattr(output,name);actual=bits(value) if name in ['frequency','mean_position','mean_duration','raw_score','probability'] else value
                if actual!=reference:differences.append(dict(run=i,field=name,native=hex(actual),reference=hex(reference)))
        if totals:
            actual=[bits(s) for s in scores]
            if actual!=totals[-1]['typeScoreBits']:differences.append(dict(field='typeScores',native=actual,reference=totals[-1]['typeScoreBits']))
    used=bytes(runs)[:selection.scored_runs*C.sizeof(Run)]
    return dict(exact=not differences,selected=[selection.section_type,selection.beat_index],scoredRuns=selection.scored_runs,
                typeScoreBits=list(struct.unpack('<'+'I'*types,bytes(scores))) if types else [],
                runSHA256=hashlib.sha256(used).hexdigest(),differences=differences)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    p.add_argument('--candidates-report',type=Path);p.add_argument('--synthetic',action='store_true')
    p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    lib=C.CDLL(str(args.library.resolve()));lib.negi_sensme_chorus_select.argtypes=[C.POINTER(C.c_float),C.POINTER(C.c_int32),C.c_size_t,C.c_size_t,
        C.POINTER(C.c_float),C.c_size_t,C.POINTER(Selection),C.POINTER(C.c_float),C.POINTER(Run)]
    report=json.loads(args.report.read_text())
    if args.synthetic:
        results=[]
        for case in report['cases']:
            if not case['unobservedVerified']:raise ValueError('Synthetic observation was not verified')
            values=inputs(case['kind'],case['pattern'],case['count'])
            result=check(lib,*values,case['selected'],case['observations'])
            results.append(dict(kind=case['kind'],pattern=case['pattern'],count=case['count'],**result))
        output=dict(exact=all(r['exact'] for r in results),cases=results)
        args.out.write_text(json.dumps(output,indent=2)+'\n')
        print(json.dumps(dict(exact=output['exact'],cases=len(results),scoredRuns=sum(c['scoredRuns'] for c in results),
                              differences=[r for r in results if not r['exact']][:8])))
        return 0 if output['exact'] else 1
    if not args.candidates_report:p.error('Private real comparison requires --candidates-report')
    tc=json.loads(args.candidates_report.read_text())
    if tc['pcmSHA256']!=report['pcmSHA256'] or not report['unobservedVerified']:raise ValueError('Private references differ')
    stages={s['stage']:s for s in report['observations']};raw=local_path(tc['energyBlocksPath']).read_bytes()
    if hashlib.sha256(raw).hexdigest()!=tc['energySHA256']:raise ValueError('Energy digest differs')
    n=stages['refined_period']['frames']//128;stats=array.array('f')
    lib.negi_sensme_spectral_create.argtypes=[C.c_int];lib.negi_sensme_spectral_create.restype=C.c_void_p
    lib.negi_sensme_spectral_destroy.argtypes=[C.c_void_p]
    lib.negi_sensme_spectral_block.argtypes=[C.c_void_p,C.POINTER(C.c_uint16),C.POINTER(C.c_float),C.POINTER(C.c_float),C.POINTER(C.c_float)]
    state=lib.negi_sensme_spectral_create(1)
    if not state:raise RuntimeError('Native statistics allocation failed')
    try:
        for block in range(n):
            source=(C.c_uint16*(128*72)).from_buffer_copy(raw[block*128*144:(block+1)*128*144])
            means=(C.c_float*16)();deviations=(C.c_float*16)()
            if not lib.negi_sensme_spectral_block(state,source,means,deviations,None):raise RuntimeError('Native statistics failed')
            stats.extend(means);stats.extend(deviations)
    finally:lib.negi_sensme_spectral_destroy(state)
    before=local_path(stages['coarse_sections']['beatsPath']).read_bytes();after_state=local_path(stages['refined_sections']['statePath']).read_bytes()
    count=len(before)//168;times=[struct.unpack_from('<f',before,i*168)[0] for i in range(count)]
    labels=[struct.unpack_from('<i',before,i*168+164)[0] for i in range(count)]
    types=struct.unpack_from('<I',after_state,0x48c)[0];expected=list(struct.unpack_from('<II',after_state,0x490))
    output=check(lib,times,labels,types,stats,n,expected,[e for e in report['observations'] if e['stage'].startswith('chorus_')])
    args.out.write_text(json.dumps(output,indent=2)+'\n');print(json.dumps(output))
    return 0 if output['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
