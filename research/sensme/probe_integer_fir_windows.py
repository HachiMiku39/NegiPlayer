"""Generate synthetic differential vectors from an owner-supplied audited DLL.

Local research tool, never loaded by NegiPlayer. Requires Windows x86 Python;
no Wine, COM registration, network access, or music-file mutation.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct

AUDITED_SHA256 = "884ecce288bcaa4e9c94f49f514fb00cee2ba2f5bac8fcb9ef63690e4e529a04"


def signed_word(value):
    value &= 65535
    return value - 65536 if value >= 32768 else value


def vectors(taps, kind, count=65536):
    seed = 0x39C0FFEE
    coefficients = []
    for _ in range(taps):
        seed = (1664525 * seed + 1013904223) & 0xffffffff
        coefficients.append(signed_word(seed >> 16))
    samples = []
    for i in range(count):
        seed = (1664525 * seed + 1013904223) & 0xffffffff
        if kind == "random": value = signed_word(seed >> 16)
        elif kind == "impulse": value = -32768 if i == 0 else 0
        elif kind == "limits": value = [-32768, 32767, -1, 0, 1][i % 5]
        elif kind == "overflow": value = -32768
        else: raise ValueError(kind)
        samples.append(value)
    if kind == "overflow": coefficients = [-32768] * taps
    return coefficients, samples


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dll", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()
    if C.sizeof(C.c_void_p) != 4:
        raise RuntimeError("This audited probe requires x86 Python")
    digest = hashlib.sha256(args.dll.read_bytes()).hexdigest()
    if digest != AUDITED_SHA256:
        raise RuntimeError("DLL mismatch; internal offsets are valid only for the audited binary")
    kernel = C.WinDLL("kernel32", use_last_error=True)
    kernel.LoadLibraryW.argtypes = [C.c_wchar_p]
    kernel.LoadLibraryW.restype = C.c_void_p
    kernel.VirtualAlloc.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.c_uint32]
    kernel.VirtualAlloc.restype = C.c_void_p
    kernel.VirtualProtect.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(C.c_uint32)]
    kernel.VirtualFree.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32]
    kernel.GetCurrentProcess.restype = C.c_void_p
    kernel.FlushInstructionCache.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    module = kernel.LoadLibraryW(str(args.dll.resolve()))
    if not module: raise C.WinError(C.get_last_error())
    # cdecl (this, sample) -> audited __thiscall FIR. Callee removes sample.
    # No code/data in the DLL is patched. The private thunk changes only calling
    # convention and calls the same FIR selected by the original vtable.
    code = (b"\x55\x89\xe5\x8b\x4d\x08\xff\x75\x0c\xba"
            + struct.pack("<I", module + 0x24b80)
            + b"\xff\xd2\x89\xec\x5d\xc3")
    thunk = kernel.VirtualAlloc(None, len(code), 0x3000, 0x04)
    if not thunk: raise C.WinError(C.get_last_error())
    try:
        C.memmove(thunk, code, len(code))
        previous = C.c_uint32()
        if not kernel.VirtualProtect(thunk, len(code), 0x20, C.byref(previous)):
            raise C.WinError(C.get_last_error())
        kernel.FlushInstructionCache(kernel.GetCurrentProcess(), thunk, len(code))
        call = C.CFUNCTYPE(C.c_int32, C.c_void_p, C.c_int32)(thunk)
        cases = []
        for taps in (47, 256):
            padded = (taps + 15) & ~15
            for kind in ("random", "impulse", "limits", "overflow"):
                coeff, samples = vectors(taps, kind)
                coefficients = (C.c_int16 * padded)(*coeff)
                history = (C.c_int16 * (taps + padded))()
                obj = (C.c_uint32 * 9)(0, C.addressof(coefficients), C.addressof(history),
                                            taps, 0, padded, C.addressof(coefficients), 0, padded // 4)
                output = bytearray()
                retained = bytearray()
                for i, sample in enumerate(samples):
                    result = signed_word(call(C.byref(obj), sample))
                    word = struct.pack("<h", result)
                    output.extend(word)
                    if i % 2 == 0: retained.extend(word)
                cases.append(dict(taps=taps, kind=kind, samples=len(samples),
                                  sha256=hashlib.sha256(output).hexdigest(),
                                  decimatedSHA256=hashlib.sha256(retained).hexdigest(),
                                  first16=list(struct.unpack("<16h", output[:32]))))
        args.out.write_text(json.dumps(dict(schemaVersion=1, dllSHA256=digest,
                                           functionRVA="0x24b80", cases=cases), indent=2)+"\n")
        print(json.dumps(dict(cases=len(cases), samples=sum(x['samples'] for x in cases))))
    finally:
        kernel.VirtualFree(thunk, 0, 0x8000)


if __name__ == "__main__": main()
