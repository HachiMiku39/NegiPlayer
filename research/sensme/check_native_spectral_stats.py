"""Compare native statistics with private DLL intermediate-series captures."""
import argparse
import array
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct


def local_path(value):
    prefix='\\\\Mac\\Home\\'
    return Path.home()/value[len(prefix):].replace('\\','/') if value.startswith(prefix) else Path(value)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--report',type=Path,required=True)
    p.add_argument('--features',type=Path,required=True);p.add_argument('--out-prefix',type=Path,required=True)
    args=p.parse_args();report=json.loads(args.report.read_text());raw=args.features.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=report['inputSHA256']:raise ValueError('Input feature digest differs')
    values=array.array('H');values.frombytes(raw)
    lib=C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_spectral_create.argtypes=[C.c_int];lib.negi_sensme_spectral_create.restype=C.c_void_p
    lib.negi_sensme_spectral_destroy.argtypes=[C.c_void_p];lib.negi_sensme_spectral_destroy.restype=None
    lib.negi_sensme_spectral_block.argtypes=[C.c_void_p,C.POINTER(C.c_uint16),C.POINTER(C.c_float),C.POINTER(C.c_float),C.POINTER(C.c_float)]
    lib.negi_sensme_spectral_block.restype=C.c_int
    lib.negi_sensme_spectral_summary.argtypes=[C.POINTER(C.c_float),C.c_size_t,C.POINTER(C.c_float)]
    lib.negi_sensme_spectral_summary.restype=C.c_int
    output=[]
    for profile in report['profiles']:
        state=lib.negi_sensme_spectral_create(profile['mode'])
        if not state:raise RuntimeError('Native kernel allocation failed')
        expected_series=local_path(profile['seriesPath']).read_bytes()
        expected_summary=local_path(profile['summaryPath']).read_bytes()
        mismatches=[0]*16;first={};summary_mismatches=0
        prefix=str(args.out_prefix)+'.profile-'+str(profile['mode'])
        try:
            with Path(prefix+'.series.f32le').open('wb') as series_out,Path(prefix+'.summary.f32le').open('wb') as summary_out:
                for block in range(report['blocks']):
                    at=(report['skippedFrames']+block*128)*144
                    source=(C.c_uint16*(128*72)).from_buffer(values,at)
                    means=(C.c_float*16)();deviations=(C.c_float*16)();series=(C.c_float*(16*128))()
                    if not lib.negi_sensme_spectral_block(state,source,means,deviations,series):raise RuntimeError('Native block failed')
                    actual=bytes(series);wanted=expected_series[block*8192:(block+1)*8192]
                    series_out.write(actual);summary=bytes(means)+bytes(deviations);summary_out.write(summary)
                    summary_mismatches+=sum(summary[i:i+4]!=expected_summary[block*128+i:block*128+i+4] for i in range(0,128,4))
                    for stream in range(16):
                        for frame in range(128):
                            i=(stream*128+frame)*4
                            if actual[i:i+4]!=wanted[i:i+4]:
                                mismatches[stream]+=1
                                if str(stream) not in first:
                                    a,b=struct.unpack('<f',actual[i:i+4])[0],struct.unpack('<f',wanted[i:i+4])[0]
                                    first[str(stream)]=dict(block=block,frame=frame,native=a,reference=b,
                                                          nativeBits=actual[i:i+4].hex(),referenceBits=wanted[i:i+4].hex())
        finally:lib.negi_sensme_spectral_destroy(state)
        aggregate_mismatches=0
        if profile.get('trackSummaryPath'):
            data=array.array('f');data.frombytes(Path(prefix+'.summary.f32le').read_bytes())
            source=(C.c_float*len(data)).from_buffer(data);aggregate=(C.c_float*64)()
            if not lib.negi_sensme_spectral_summary(source,report['blocks'],aggregate):raise RuntimeError('Native aggregation failed')
            payload=bytes(aggregate);expected=local_path(profile['trackSummaryPath']).read_bytes()
            Path(prefix+'.track-summary.f32le').write_bytes(payload)
            aggregate_mismatches=sum(payload[i:i+4]!=expected[i:i+4] for i in range(0,256,4))
        output.append(dict(mode=profile['mode'],blocks=report['blocks'],seriesMismatches=mismatches,
                           summaryMismatches=summary_mismatches,aggregateMismatches=aggregate_mismatches,firstDifferences=first))
    result=dict(exact=all(not any(x['seriesMismatches']) and not x['summaryMismatches'] and not x['aggregateMismatches'] for x in output),profiles=output)
    Path(str(args.out_prefix)+'.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
    return 0 if result['exact'] else 1


if __name__=='__main__':raise SystemExit(main())
