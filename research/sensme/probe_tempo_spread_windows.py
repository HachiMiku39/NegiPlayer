"""Probe audited log-bin conversion and weighted spread with generated inputs.

This private research process never modifies music or the DLL. A tiny thunk
adapts the logarithmic expression's x87 argument for the conversion helper.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe_integer_fir_windows import AUDITED_SHA256
from synthetic_tempo_spread_input import profiles, spectra


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll', type=Path, required=True); p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    if C.sizeof(C.c_void_p) != 4 or hashlib.sha256(args.dll.read_bytes()).hexdigest() != AUDITED_SHA256:
        raise RuntimeError('Audited DLL and x86 Python required')
    k = C.WinDLL('kernel32', use_last_error=True)
    k.LoadLibraryW.argtypes = [C.c_wchar_p]; k.LoadLibraryW.restype = C.c_void_p
    k.FreeLibrary.argtypes = [C.c_void_p]
    k.VirtualAlloc.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.c_uint32]; k.VirtualAlloc.restype = C.c_void_p
    k.VirtualProtect.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(C.c_uint32)]
    k.VirtualFree.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32]
    k.GetCurrentProcess.restype = C.c_void_p; k.FlushInstructionCache.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    module = k.LoadLibraryW(str(args.dll.resolve())); pages = []
    if not module: raise C.WinError(C.get_last_error())
    def address(rva): return struct.pack('<I', module + rva)
    def thunk(code):
        page = k.VirtualAlloc(None, len(code), 0x3000, 4)
        if not page: raise C.WinError(C.get_last_error())
        pages.append(page); C.memmove(page, code, len(code)); old = C.c_uint32()
        if not k.VirtualProtect(page, len(code), 0x20, C.byref(old)): raise C.WinError(C.get_last_error())
        k.FlushInstructionCache(k.GetCurrentProcess(), page, len(code)); return page
    try:
        # Same log expression and conversion helper as the original band-2
        # accumulator. Leave no live x87 values on return to Python.
        code = (b'\xdd\x05' + address(0x3e728) + b'\xd9\xed\xd9\xc9\xd9\xf1\xd8\x3d' + address(0x3a0a4)
                + b'\xdb\x44\x24\x04\xdc\x0d' + address(0x3e728) + b'\xdc\x0d' + address(0x3e720)
                + b'\xd9\xed\xd9\xc9\xd9\xf1\xd8\xc9\xd8\x0d' + address(0x3e5cc)
                + b'\xba' + address(0x305b4) + b'\xff\xd2\xdd\xd8\xc3')
        convert = C.CFUNCTYPE(C.c_int32, C.c_int32)(thunk(code))
        apply = C.WINFUNCTYPE(None, C.c_void_p, C.c_void_p, C.c_int32)(module + 0x165f0)
        release = C.CFUNCTYPE(None, C.c_void_p)(module + 0x28b3d)
        mapping = [convert(i) for i in range(1, 2048)]
        cases = []
        for kind, segments in profiles():
            weights = [0.0] * 256
            for spectrum in spectra(kind, segments):
                for bin, index in enumerate(mapping, 1):
                    if 0 <= index < 256:
                        weights[index] = struct.unpack('<f', struct.pack('<f', weights[index] + spectrum[bin]))[0]
            data = (C.c_float * 246)(*weights[10:]); shape = (C.c_uint32 * 2)(246, 0)
            source = (C.c_uint32 * 5)(C.addressof(data), 246, 1, C.addressof(shape), 0)
            output = (C.c_uint32 * 5)(0, 0, 0, 0, 0xffffffff)
            apply(source, output, 0)
            if not output[0] or output[1] != 1 or output[2] != 0: raise ValueError('Unexpected reduced scalar shape')
            bits = C.c_uint32.from_address(output[0]).value
            release(output[0]); release(output[3])
            cases.append(dict(kind=kind, segments=segments, profileSHA256=hashlib.sha256(struct.pack('<256f', *weights)).hexdigest(), spreadBits=bits))
        args.out.write_text(json.dumps(dict(schemaVersion=1, dllSHA256=AUDITED_SHA256, mapping=mapping, cases=cases), indent=2) + '\n')
        print(json.dumps(dict(mappingBins=len(mapping), cases=len(cases))))
    finally:
        for page in pages: k.VirtualFree(page, 0, 0x8000)
        k.FreeLibrary(module)


if __name__ == '__main__': main()
