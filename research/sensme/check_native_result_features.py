"""Compare independent native feature collection with the audited collector."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from synthetic_result_input import make
from check_native_spectral_stats import local_path


class Beat(C.Structure):
    _fields_ = [('milliseconds', C.c_float), ('bar', C.c_int32), ('beat', C.c_int32),
                ('tonal_class', C.c_int32), ('probabilities', C.c_float * 24), ('reserved_features', C.c_float * 14)]


class Key(C.Structure):
    _fields_ = [('root', C.c_int32), ('probabilities', C.c_float * 12)]


class Result(C.Structure):
    _fields_ = [('words', C.c_uint32 * 189)]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library', type=Path, required=True); p.add_argument('--oracle', type=Path, required=True)
    p.add_argument('--real-report', type=Path); p.add_argument('--out', type=Path, required=True); args = p.parse_args()
    oracle = json.loads(args.oracle.read_text()); lib = C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_result_features.argtypes = [C.POINTER(Beat), C.POINTER(Key), C.POINTER(C.c_int32), C.c_size_t,
        C.POINTER(C.c_float), C.c_float, C.c_float, C.c_float, C.c_int32, C.c_size_t, C.POINTER(Result)]
    results = []
    for case in oracle['cases']:
        n = case['count']
        if oracle['realInput']:
            if not args.real_report: p.error('Private reference requires --real-report')
            trace = json.loads(args.real_report.read_text())
            if trace['dllSHA256'] != oracle['dllSHA256']: raise ValueError('Audited input differs')
            stage = next(v for v in trace['observations'] if v['stage'] == 'section_keys_ready')
            if stage['count'] != n: raise ValueError('Beat count differs')
            state = local_path(stage['statePath']).read_bytes()
            spec = dict(beats=local_path(stage['beatsPath']).read_bytes(), summaries=list(struct.unpack_from('<128f', state, 0x15c)),
                chorusType=struct.unpack_from('<i', state, 0x490)[0], chorusBeat=struct.unpack_from('<i', state, 0x494)[0])
            for offset, key in [(0x468, 'bpm'), (0x46c, 'logBpm'), (0x470, 'spectrumSpread')]: spec[key] = struct.unpack_from('<f', state, offset)[0]
        else: spec = make(case['kind'], case['pattern'], n)
        beats = (Beat * n).from_buffer_copy(spec['beats']); keys = (Key * n)(); sections = (C.c_int32 * n)()
        for i in range(n):
            keys[i] = Key.from_buffer_copy(spec['beats'], i * 168 + 112)
            sections[i] = struct.unpack_from('<i', spec['beats'], i * 168 + 164)[0]
        out = Result(); before = [bytes(beats), bytes(keys), bytes(sections)]
        status = lib.negi_sensme_result_features(beats, keys, sections, n, (C.c_float * 128)(*spec['summaries']),
            spec['bpm'], spec['logBpm'], spec['spectrumSpread'], spec['chorusType'], spec['chorusBeat'], C.byref(out))
        if before != [bytes(beats), bytes(keys), bytes(sections)]: raise RuntimeError('Native collector modified input')
        payload = bytes(out); differences = [dict(offset=hex(i * 4 + 0x10), native=a, reference=b)
            for i, (a, b) in enumerate(zip(out.words, case['words'])) if a != b]
        exact = bool(status) and not differences if case['safeChorusCapacity'] else not status
        if hashlib.sha256(struct.pack('<189I', *case['words'])).hexdigest() != case['SHA256']: raise ValueError('Oracle digest differs')
        results.append(dict(kind=case.get('kind'), pattern=case.get('pattern'), count=n, exact=exact,
            nativeSHA256=hashlib.sha256(payload).hexdigest(), referenceSHA256=case['SHA256'], differences=differences))
    result = dict(exact=all(c['exact'] for c in results), cases=results)
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(exact=result['exact'], cases=len(results), mismatches=sum(len(c['differences']) for c in results))))
    return 0 if result['exact'] else 1


if __name__ == '__main__': raise SystemExit(main())
