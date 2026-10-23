"""Compare the complete native PCM interface with generated original-engine results."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
from synthetic_analysis_input import make


class Summary(C.Structure):
    _fields_ = [('input_frames', C.c_uint64), ('leading_zero_frames', C.c_uint64),
                ('processed_frames', C.c_size_t), ('beat_count', C.c_size_t),
                ('descriptor_padding_pairs', C.c_size_t), ('is_short', C.c_int),
                ('has_bpm', C.c_int), ('bpm', C.c_float)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--oracle', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    oracle = json.loads(args.oracle.read_text())
    if oracle.get('realInput') is not False:
        raise ValueError('This checker only generates synthetic PCM')
    lib = C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_analyzer_create.restype = C.c_void_p
    lib.negi_sensme_analyzer_destroy.argtypes = [C.c_void_p]
    lib.negi_sensme_analyzer_write.argtypes = [C.c_void_p, C.POINTER(C.c_int16), C.c_size_t]
    lib.negi_sensme_analyzer_finish.argtypes = [C.c_void_p, C.POINTER(C.c_uint8), C.c_size_t, C.POINTER(Summary)]
    lib.negi_sensme_analyzer_finish.restype = C.c_size_t
    results = []
    for index, item in enumerate(oracle['cases']):
        if item['kind'] != 'generated-complete-analysis' or not item.get('unobservedVerified'):
            raise ValueError('Expected complete results verified against unobserved original runs')
        raw = bytearray(make(item['spec']))
        if hashlib.sha256(raw).hexdigest() != item['pcmSHA256']:
            raise ValueError('Generated PCM differs')
        expected = bytes.fromhex(item['encodedHex'])
        if hashlib.sha256(expected).hexdigest() != item['encodedSHA256']:
            raise ValueError('Oracle result digest differs')
        state = lib.negi_sensme_analyzer_create()
        if not state: raise RuntimeError('Allocation failed')
        try:
            for start in range(0, len(raw)//4, 4096):
                count = min(4096, len(raw)//4 - start)
                samples = (C.c_int16 * (2*count)).from_buffer(raw, start*4)
                if not lib.negi_sensme_analyzer_write(state, samples, count):
                    raise RuntimeError(('PCM input failed', index))
            summary = Summary()
            size = lib.negi_sensme_analyzer_finish(state, None, 0, C.byref(summary))
            if not size: raise RuntimeError(('Analysis finalization failed', index))
            output = (C.c_uint8 * (size+16))(*([0xa5] * (size+16)))
            written = lib.negi_sensme_analyzer_finish(state, output, size, C.byref(summary))
            actual = bytes(output)[:written]
            if bytes(output)[size:] != bytes([0xa5]*16):
                raise RuntimeError('Result exceeds output extent')
            if hashlib.sha256(raw).hexdigest() != item['pcmSHA256']:
                raise RuntimeError('Native analysis changed caller PCM')
            result = dict(case=index, spec=item['spec'], queriedBytes=size, writtenBytes=written,
                          expectedBytes=len(expected), exact=actual == expected,
                          summary={name: getattr(summary, name) for name, _ in Summary._fields_})
            if actual != expected:
                result['firstDifference'] = next((i for i, (a,b) in enumerate(zip(actual, expected))
                                                   if a != b), min(len(actual), len(expected)))
            results.append(result)
        finally:
            lib.negi_sensme_analyzer_destroy(state)
    result = dict(exact=all(item['exact'] for item in results), cases=results,
                  sourceMusicWrites=False, productionEntryReplaced=False)
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(cases=len(results), exact=result['exact'],
                          failures=[r for r in results if not r['exact']])))
    return 0 if result['exact'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
