"""Compare a native core shared library with synthetic Sony-oracle digests."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from probe_integer_fir_windows import vectors


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--library", type=Path, required=True)
    p.add_argument("--oracle", type=Path, required=True)
    args = p.parse_args()
    library = C.CDLL(str(args.library.resolve()))
    library.negi_sensme_fir_create.argtypes = [C.POINTER(C.c_int16), C.c_size_t]
    library.negi_sensme_fir_create.restype = C.c_void_p
    library.negi_sensme_fir_push.argtypes = [C.c_void_p, C.c_int16]
    library.negi_sensme_fir_push.restype = C.c_int16
    library.negi_sensme_fir_feed.argtypes = [C.c_void_p, C.c_int16]
    library.negi_sensme_fir_feed.restype = None
    library.negi_sensme_fir_destroy.argtypes = [C.c_void_p]
    library.negi_sensme_fir_destroy.restype = None
    library.negi_sensme_fir_reset.argtypes = [C.c_void_p]
    library.negi_sensme_fir_reset.restype = None
    tests, samples_checked = [], 0
    for case in json.loads(args.oracle.read_text())["cases"]:
        coefficients, samples = vectors(case["taps"], case["kind"], case["samples"])
        taps = (C.c_int16 * len(coefficients))(*coefficients)
        handle = library.negi_sensme_fir_create(taps, len(coefficients))
        if not handle: raise RuntimeError("Native filter allocation failed")
        try:
            out = bytearray()
            for sample in samples:
                out.extend(struct.pack("<h", library.negi_sensme_fir_push(handle, sample)))
            digest = hashlib.sha256(out).hexdigest()
            if digest != case["sha256"]:
                raise AssertionError((case["kind"], case["taps"], digest, case["sha256"]))
            library.negi_sensme_fir_reset(handle)
            out = bytearray()
            for i, sample in enumerate(samples):
                if i % 2:
                    library.negi_sensme_fir_feed(handle, sample)
                else:
                    out.extend(struct.pack("<h", library.negi_sensme_fir_push(handle, sample)))
            if hashlib.sha256(out).hexdigest() != case["decimatedSHA256"]:
                raise AssertionError("Feed-only phase or reset changed the next output")
            samples_checked += len(samples) * 2
            tests.append(dict(taps=case["taps"], kind=case["kind"], exact=True))
        finally:
            library.negi_sensme_fir_destroy(handle)
    print(json.dumps(dict(cases=tests, sampleOperations=samples_checked, exact=True)))


if __name__ == "__main__": main()
