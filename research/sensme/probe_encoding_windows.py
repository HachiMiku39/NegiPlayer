"""Observe the original default SMFMF formatter on caller-owned input only."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe_integer_fir_windows import AUDITED_SHA256


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if C.sizeof(C.c_void_p) != 4 or hashlib.sha256(args.dll.read_bytes()).hexdigest() != AUDITED_SHA256:
        raise RuntimeError('Audited DLL and Windows x86 Python required')
    k = C.WinDLL('kernel32', use_last_error=True)
    k.LoadLibraryW.argtypes = [C.c_wchar_p]; k.LoadLibraryW.restype = C.c_void_p
    k.FreeLibrary.argtypes = [C.c_void_p]
    k.VirtualAlloc.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.c_uint32]; k.VirtualAlloc.restype = C.c_void_p
    k.VirtualProtect.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(C.c_uint32)]
    k.VirtualFree.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32]
    k.GetCurrentProcess.restype = C.c_void_p; k.FlushInstructionCache.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    module = k.LoadLibraryW(str(args.dll.resolve())); page = None
    if not module: raise C.WinError(C.get_last_error())
    try:
        code = (b'\x55\x89\xe5\x53\x56\x57\x8b\x4d\x08\x31\xd2\xff\x75\x10\xff\x75\x0c\xb8'
                + struct.pack('<I', module + 0x23260)
                + b'\xff\xd0\x8d\x65\xf4\x5f\x5e\x5b\x5d\xc3')
        page = k.VirtualAlloc(None, len(code), 0x3000, 4)
        if not page: raise C.WinError(C.get_last_error())
        C.memmove(page, code, len(code)); old = C.c_uint32()
        if not k.VirtualProtect(page, len(code), 0x20, C.byref(old)): raise C.WinError(C.get_last_error())
        k.FlushInstructionCache(k.GetCurrentProcess(), page, len(code))
        run = C.CFUNCTYPE(C.c_uint32, C.c_void_p, C.c_void_p, C.c_void_p)(page)
        source = json.loads(args.input.read_text()); cases = []
        for item in source['cases']:
            case = dict(item)
            state = (C.c_ubyte * 0xcf8)(); context = (C.c_uint32 * (0x308 // 4))()
            raw = bytes.fromhex(case['beatsHex']); beats = (C.c_ubyte * max(1, len(raw)))()
            if raw: C.memmove(beats, raw, len(raw))
            count = len(raw) // 168
            if len(raw) != count * 168: raise ValueError('Partial beat record')
            C.c_uint32.from_buffer(state, 0x128).value = case['processedFrames']
            C.c_uint32.from_buffer(state, 0x154).value = case['volumeBits']
            C.c_uint32.from_buffer(state, 0x474).value = C.addressof(beats) if count else 0
            C.c_uint32.from_buffer(state, 0x478).value = count
            C.c_int32.from_buffer(state, 0x490).value = case['chorusType']
            C.c_uint32.from_buffer(state, 0x494).value = case['chorusBeat']
            context[3] = C.addressof(state)
            C.memmove(C.addressof(context) + 0x10, (C.c_uint32 * 189)(*case['words']), 756)
            # STAE/MMLW, schema1.0, big-endian flag, PCM44.1k/stereo16,
            # caller sample offset, and default output mask.
            descriptor = C.create_string_buffer(b'STAEMMLW\x01\x00\x00\x80' + struct.pack('<I4BII', 44100, 2, 16, 0, 0, case['sampleOffset'], 0))
            before = bytes(state), bytes(context), bytes(beats), bytes(descriptor)
            size = run(descriptor, context, None)
            if not 0 < size <= 200000: raise RuntimeError(('Unexpected encoded size', size))
            output = (C.c_ubyte * size)()
            if run(descriptor, context, output) != size: raise RuntimeError('Size query differs from actual output')
            if before != (bytes(state), bytes(context), bytes(beats), bytes(descriptor)):
                raise RuntimeError('Formatter modified caller input')
            blob = bytes(output)
            case.update(encodedHex=blob.hex(), encodedSHA256=hashlib.sha256(blob).hexdigest(), encodedBytes=size)
            if case.get('fullEngineSHA256') and case['fullEngineSHA256'] != case['encodedSHA256']:
                raise RuntimeError(('Recreated formatting differs from captured complete engine result', case.get('case')))
            cases.append(case)
        args.out.write_text(json.dumps(dict(schemaVersion=1, dllSHA256=AUDITED_SHA256,
                                            realInput=source.get('realInput', False), cases=cases), separators=(',', ':')) + '\n')
        print(json.dumps(dict(cases=len(cases), encodedBytes=sum(c['encodedBytes'] for c in cases), inputUnchanged=True)))
    finally:
        if page: k.VirtualFree(page, 0, 0x8000)
        k.FreeLibrary(module)


if __name__ == '__main__': main()
