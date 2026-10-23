"""Observe the audited DLL's PCM preparation on synthetic inputs only.

In this isolated research process, replace the downstream feature function
with a capture callback, then restore its original entry bytes. The DLL file
and installed applications are never modified. This is not a playback backend.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
# The owner's embeddable Python intentionally excludes the script directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe_integer_fir_windows import AUDITED_SHA256, signed_word


def pcm_cases():
    seed = 0x3912ABCD
    random = []
    for _ in range(20000):
        seed = (1664525 * seed + 1013904223) & 0xffffffff
        random.append(signed_word(seed >> 16))
    return [
        ("stereo-random", 2, [0] * 514 + random),
        ("stereo-antiphase", 2, [0, 0, 100, -100, 0, 0, -1, 0, -32768, 32767] * 4097),
        ("stereo-silence", 2, [0] * 30000),
        ("mono-random", 1, [0] * 257 + random),
        ("mono-limits", 1, [0, -32768, 32767, -1, 0, 1] * 4001),
    ]


def partitions(frames):
    at = 0
    for n in [1, 3, 7, 13, 4097, 1, 5, 127] * (frames // 4000 + 2):
        if at >= frames: return
        count = min(n, frames - at)
        yield at, count
        at += count
    if at < frames: yield at, frames - at


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dll", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()
    if C.sizeof(C.c_void_p) != 4 or hashlib.sha256(args.dll.read_bytes()).hexdigest() != AUDITED_SHA256:
        raise RuntimeError("Requires audited DLL and x86 Python")
    k = C.WinDLL("kernel32", use_last_error=True)
    k.LoadLibraryW.argtypes = [C.c_wchar_p]; k.LoadLibraryW.restype = C.c_void_p
    k.VirtualProtect.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(C.c_uint32)]
    k.GetCurrentProcess.restype = C.c_void_p
    k.FlushInstructionCache.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    k.CreateEventW.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_void_p]
    k.CreateEventW.restype = C.c_void_p
    k.CloseHandle.argtypes = [C.c_void_p]
    module = k.LoadLibraryW(str(args.dll.resolve()))
    if not module: raise C.WinError(C.get_last_error())
    downstream = module + 0x25650
    original = C.string_at(downstream, 7)
    if original != bytes.fromhex("83ec1c53558b6c"):
        raise RuntimeError("Unexpected audited function prologue")
    output = bytearray()
    errors = []

    # The internal function ends in ret 12 (stdcall), despite Ghidra's default
    # inferred signature. Preserving stack cleanup is essential for observation.
    @C.WINFUNCTYPE(None, C.c_void_p, C.c_void_p, C.c_int32)
    def capture(feature_state, samples, count):
        if not feature_state or not samples or not 0 < count <= 4096:
            errors.append("Invalid capture arguments")
        else:
            output.extend(C.string_at(samples, count * 2))

    replacement = b"\xb8" + struct.pack("<I", C.cast(capture, C.c_void_p).value) + b"\xff\xe0"
    previous = C.c_uint32()
    if not k.VirtualProtect(downstream, len(original), 0x40, C.byref(previous)):
        raise C.WinError(C.get_last_error())
    try:
        C.memmove(downstream, replacement, len(replacement))
        k.FlushInstructionCache(k.GetCurrentProcess(), downstream, len(original))
        prepare = C.WINFUNCTYPE(None, C.c_void_p)(module + 0x58b0)
        results = []
        for name, channels, samples in pcm_cases():
            output.clear()
            obj = (C.c_ubyte * 0xa0)()
            features = (C.c_ubyte * 0xcd4)()
            ring = (C.c_uint32 * 5)()
            C.c_uint32.from_buffer(features, 0x50c).value = C.addressof(ring)
            C.c_uint32.from_buffer(obj, 0x50).value = C.addressof(features)
            C.c_uint32.from_buffer(obj, 0x2c).value = channels
            C.c_uint32.from_buffer(obj, 0x34).value = 16
            event = k.CreateEventW(None, 1, 0, None)
            if not event: raise C.WinError(C.get_last_error())
            C.c_uint32.from_buffer(obj, 0x88).value = event
            try:
                for at, frames in partitions(len(samples) // channels):
                    data = (C.c_int16 * (frames * channels))(*samples[at*channels:(at+frames)*channels])
                    C.c_uint32.from_buffer(obj, 0x7c).value = C.addressof(data)
                    C.c_uint32.from_buffer(obj, 0x80).value = C.sizeof(data)
                    prepare(C.byref(obj))
                results.append(dict(name=name, channels=channels, outputFrames=len(output)//2,
                                    sha256=hashlib.sha256(output).hexdigest(),
                                    leadingZeroFrames=C.c_uint32.from_buffer(obj, 0x4c).value,
                                    hasSignal=bool(obj[0x48])))
            finally:
                k.CloseHandle(event)
        if errors: raise AssertionError(errors)
        args.out.write_text(json.dumps(dict(schemaVersion=1, dllSHA256=AUDITED_SHA256,
                                           functionRVA="0x58b0", cases=results),indent=2)+"\n")
        print(json.dumps(dict(cases=len(results), exactInputs="synthetic-only")))
    finally:
        C.memmove(downstream, original, len(original))
        k.FlushInstructionCache(k.GetCurrentProcess(), downstream, len(original))
        ignored = C.c_uint32()
        k.VirtualProtect(downstream, len(original), previous.value, C.byref(ignored))


if __name__ == "__main__": main()
