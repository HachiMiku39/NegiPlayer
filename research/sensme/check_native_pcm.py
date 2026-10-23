"""Compare streaming native preparation with DLL-observed synthetic PCM."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
from probe_pcm_windows import pcm_cases, partitions


class State(C.Structure):
    _fields_ = [("leading_zero_frames", C.c_uint64), ("has_signal", C.c_int)]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--library", type=Path, required=True)
    p.add_argument("--oracle", type=Path, required=True)
    args = p.parse_args()
    lib = C.CDLL(str(args.library.resolve()))
    lib.negi_sensme_prepare_pcm.argtypes = [C.POINTER(State), C.POINTER(C.c_int16), C.c_size_t, C.c_uint, C.POINTER(C.c_int16)]
    lib.negi_sensme_prepare_pcm.restype = C.c_size_t
    expected = {x['name']: x for x in json.loads(args.oracle.read_text())["cases"]}
    for name, channels, samples in pcm_cases():
        state = State()
        out = bytearray()
        for at, frames in partitions(len(samples) // channels):
            data = (C.c_int16 * (frames * channels))(*samples[at*channels:(at+frames)*channels])
            # Exercise the same in-place buffer layout used by the Sony path.
            count = lib.negi_sensme_prepare_pcm(C.byref(state), data, frames, channels, data)
            if count > frames: raise AssertionError("Native preparation failed")
            out.extend(C.string_at(data, count * 2))
        result = dict(name=name, channels=channels, outputFrames=len(out)//2,
                      sha256=hashlib.sha256(out).hexdigest(),
                      leadingZeroFrames=state.leading_zero_frames, hasSignal=bool(state.has_signal))
        if result != expected[name]: raise AssertionError((result, expected[name]))
    print(json.dumps(dict(cases=len(expected), exact=True)))


if __name__ == "__main__": main()
