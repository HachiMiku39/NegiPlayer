"""Compare native tone/onset features with private audited DLL captures."""
import argparse
import array
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from check_native_spectral_stats import local_path


def compare(actual, expected, word_bytes):
    failures = sum(actual[i:i+word_bytes] != expected[i:i+word_bytes] for i in range(0, len(expected), word_bytes))
    first = None
    if failures:
        at = next(i for i in range(0, len(expected), word_bytes) if actual[i:i+word_bytes] != expected[i:i+word_bytes])
        fmt = '<f' if word_bytes == 4 else '<H'
        first = dict(index=at//word_bytes, native=struct.unpack(fmt, actual[at:at+word_bytes])[0],
                     reference=struct.unpack(fmt, expected[at:at+word_bytes])[0])
    return dict(mismatches=failures, first=first, SHA256=hashlib.sha256(actual).hexdigest())


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library', type=Path, required=True); p.add_argument('--report', type=Path, required=True)
    p.add_argument('--features', type=Path, required=True); p.add_argument('--out-prefix', type=Path, required=True)
    args = p.parse_args(); report = json.loads(args.report.read_text()); raw = args.features.read_bytes()
    if hashlib.sha256(raw).hexdigest() != report['inputSHA256']: raise ValueError('Input digest differs')
    data = array.array('H'); data.frombytes(raw)
    lib = C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_dynamics_create.restype = C.c_void_p
    lib.negi_sensme_dynamics_destroy.argtypes = [C.c_void_p]
    lib.negi_sensme_dynamics_block.argtypes = [C.c_void_p, C.POINTER(C.c_uint16), C.POINTER(C.c_uint16), C.POINTER(C.c_float)]
    state = lib.negi_sensme_dynamics_create()
    if not state: raise RuntimeError('Allocation failed')
    tone_bytes = [bytearray() for _ in range(3)]; onset_bytes = [bytearray() for _ in range(3)]
    try:
        for block in range(report['blocks']):
            source = (C.c_uint16*(128*72)).from_buffer(data, (report['skippedFrames']+block*128)*144)
            tones = (C.c_uint16*(3*64*12))(); onsets = (C.c_float*(3*128))()
            if not lib.negi_sensme_dynamics_block(state, source, tones, onsets): raise RuntimeError('Block rejected')
            for group in range(3):
                tone_bytes[group].extend(bytes(tones)[group*1536:(group+1)*1536])
                skip = min(128, max(0, report['onsetWindow']-block*128))
                onset_bytes[group].extend(bytes(onsets)[(group*128+skip)*4:(group+1)*128*4])
    finally: lib.negi_sensme_dynamics_destroy(state)
    results = []
    for kind, payloads, width in [('tones', tone_bytes, 2), ('onsets', onset_bytes, 4)]:
        for group, payload in enumerate(payloads):
            expected = local_path(report[kind][group]['path']).read_bytes()
            if len(payload) != len(expected): raise ValueError('Feature count differs')
            Path(str(args.out_prefix)+f'.{kind}-{group}.bin').write_bytes(payload)
            results.append(dict(kind=kind, group=group, **compare(payload, expected, width)))
    output = dict(exact=all(x['mismatches'] == 0 for x in results), blocks=report['blocks'], comparisons=results)
    Path(str(args.out_prefix)+'.json').write_text(json.dumps(output, indent=2)+'\n')
    print(json.dumps(output)); return 0 if output['exact'] else 1


if __name__ == '__main__': raise SystemExit(main())
