"""Compare native default SMFMF bytes against original formatter vectors."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct


class Features(C.Structure):
    _fields_ = [('words', C.c_uint32 * 189)]


class Beat(C.Structure):
    _fields_ = [('milliseconds', C.c_float), ('bar', C.c_int32), ('beat', C.c_int32),
                ('tonal_class', C.c_int32), ('probabilities', C.c_float * 24),
                ('reserved_features', C.c_float * 14)]


class Key(C.Structure):
    _fields_ = [('root', C.c_int32), ('probabilities', C.c_float * 12)]


class Input(C.Structure):
    _fields_ = [('features', C.POINTER(Features)), ('beats', C.POINTER(Beat)),
                ('keys', C.POINTER(Key)), ('sections', C.POINTER(C.c_int32)),
                ('count', C.c_size_t), ('processed_frames', C.c_uint32),
                ('volume', C.c_float), ('chorus_type', C.c_int32),
                ('chorus_beat', C.c_size_t), ('sample_offset', C.c_uint32)]


def prepare(case):
    raw = bytes.fromhex(case['beatsHex'])
    count = len(raw) // 168
    if len(raw) % 168: raise ValueError('Partial beat record')
    features = Features((C.c_uint32 * 189)(*case['words']))
    beats, keys, sections = (Beat * count)(), (Key * count)(), (C.c_int32 * count)()
    for i in range(count):
        C.memmove(C.addressof(beats) + i * C.sizeof(Beat), raw[i*168:i*168+112], 112)
        C.memmove(C.addressof(keys) + i * C.sizeof(Key), raw[i*168+112:i*168+164], 52)
        sections[i] = struct.unpack_from('<i', raw, i*168+164)[0]
    source = Input(C.pointer(features), beats, keys, sections, count, case['processedFrames'],
                   struct.unpack('<f', struct.pack('<I', case['volumeBits']))[0],
                   case['chorusType'], case['chorusBeat'], case['sampleOffset'])
    return source, (features, beats, keys, sections)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library', type=Path, required=True)
    p.add_argument('--oracle', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    oracle = json.loads(args.oracle.read_text())
    lib = C.CDLL(str(args.library.resolve()))
    run = lib.negi_sensme_encode_smfmf
    run.argtypes = [C.POINTER(Input), C.POINTER(C.c_uint8), C.c_size_t]
    run.restype = C.c_size_t
    mismatches, passed, total_bytes = [], 0, 0
    for index, case in enumerate(oracle['cases']):
        source, keep = prepare(case)
        before = tuple(bytes(x) for x in keep)
        expected = bytes.fromhex(case['encodedHex'])
        if hashlib.sha256(expected).hexdigest() != case['encodedSHA256']:
            raise ValueError('Oracle byte digest mismatch')
        size = run(C.byref(source), None, 0)
        buffer = (C.c_uint8 * max(1, size))()
        actual_size = run(C.byref(source), buffer, size)
        actual = bytes(buffer)[:actual_size]
        if tuple(bytes(x) for x in keep) != before:
            raise RuntimeError('Native encoder changed caller input')
        total_bytes += len(expected)
        if size != len(expected) or actual != expected:
            at = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b), min(len(actual), len(expected)))
            mismatches.append(dict(case=index, kind=case['kind'], expectedBytes=len(expected),
                                   actualBytes=actual_size, queriedBytes=size, firstDifference=at,
                                   expectedHex=expected[max(0, at-8):at+16].hex(),
                                   actualHex=actual[max(0, at-8):at+16].hex()))
        else: passed += 1
    result = dict(cases=len(oracle['cases']), passed=passed, expectedBytes=total_bytes,
                  mismatches=mismatches[:100], exact=not mismatches)
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['exact'] else 1


if __name__ == '__main__': raise SystemExit(main())
