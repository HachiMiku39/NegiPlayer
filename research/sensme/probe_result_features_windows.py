"""Run original final feature collector on generated or private captured input.

Only caller-owned synthetic/context buffers are mutated. No engine patching,
music writes, or runtime integration. Pointer fields are excluded from output.
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
from synthetic_result_input import KINDS, PATTERNS, COUNTS, make


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll', type=Path, required=True); p.add_argument('--out', type=Path, required=True)
    p.add_argument('--real-report', type=Path, help='Private full-analysis beat/state observation')
    args = p.parse_args()
    if C.sizeof(C.c_void_p) != 4 or hashlib.sha256(args.dll.read_bytes()).hexdigest() != AUDITED_SHA256:
        raise RuntimeError('Audited DLL and x86 Python required')
    k = C.WinDLL('kernel32', use_last_error=True)
    k.LoadLibraryW.argtypes = [C.c_wchar_p]; k.LoadLibraryW.restype = C.c_void_p; k.FreeLibrary.argtypes = [C.c_void_p]
    k.VirtualAlloc.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.c_uint32]; k.VirtualAlloc.restype = C.c_void_p
    k.VirtualProtect.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(C.c_uint32)]
    k.VirtualFree.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32]
    k.GetCurrentProcess.restype = C.c_void_p; k.FlushInstructionCache.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    module = k.LoadLibraryW(str(args.dll.resolve())); page = None
    if not module: raise C.WinError(C.get_last_error())
    try:
        code = b'\x56\x8b\x74\x24\x08\xb8' + struct.pack('<I', module + 0x13730) + b'\xff\xd0\x5e\xc3'
        page = k.VirtualAlloc(None, len(code), 0x3000, 4)
        if not page: raise C.WinError(C.get_last_error())
        C.memmove(page, code, len(code)); old = C.c_uint32()
        if not k.VirtualProtect(page, len(code), 0x20, C.byref(old)): raise C.WinError(C.get_last_error())
        k.FlushInstructionCache(k.GetCurrentProcess(), page, len(code)); run = C.CFUNCTYPE(None, C.c_void_p)(page)
        def calculate(spec, count):
            beat_data = spec['beats']; beats = (C.c_ubyte * len(beat_data)).from_buffer_copy(beat_data)
            state = (C.c_ubyte * 0xcf8)(); context = (C.c_uint32 * (0x800 // 4))()
            C.c_uint32.from_buffer(state, 0x474).value = C.addressof(beats)
            C.c_uint32.from_buffer(state, 0x478).value = count
            C.c_int32.from_buffer(state, 0x490).value = spec['chorusType']
            C.c_int32.from_buffer(state, 0x494).value = spec['chorusBeat']
            for offset, key in [(0x468, 'bpm'), (0x46c, 'logBpm'), (0x470, 'spectrumSpread')]:
                C.c_float.from_buffer(state, offset).value = spec[key]
            C.memmove(C.addressof(state) + 0x15c, (C.c_float * 128)(*spec['summaries']), 512)
            context[3] = C.addressof(state); before = bytes(state); run(context)
            if bytes(state) != before or bytes(beats) != beat_data: raise RuntimeError('Collector modified read-only inputs')
            data = bytes(context)[0x10:0x304]; count_times = context[0x94 // 4]
            return dict(words=list(struct.unpack('<189I', data)), SHA256=hashlib.sha256(data).hexdigest(), chorusTimeCount=count_times,
                        safeChorusCapacity=count_times <= 32)
        cases = []
        if args.real_report:
            trace = json.loads(args.real_report.read_text()); stage = next(v for v in trace['observations'] if v['stage'] == 'section_keys_ready')
            state = Path(stage['statePath']).read_bytes(); spec = dict(beats=Path(stage['beatsPath']).read_bytes(),
                summaries=list(struct.unpack_from('<128f', state, 0x15c)),
                chorusType=struct.unpack_from('<i', state, 0x490)[0], chorusBeat=struct.unpack_from('<i', state, 0x494)[0])
            for offset, key in [(0x468, 'bpm'), (0x46c, 'logBpm'), (0x470, 'spectrumSpread')]: spec[key] = struct.unpack_from('<f', state, offset)[0]
            cases.append(dict(count=stage['count'], **calculate(spec, stage['count'])))
        else:
            for kind in KINDS:
                for pattern in PATTERNS:
                    for count in COUNTS: cases.append(dict(kind=kind, pattern=pattern, count=count, **calculate(make(kind, pattern, count), count)))
        args.out.write_text(json.dumps(dict(schemaVersion=1, dllSHA256=AUDITED_SHA256, realInput=bool(args.real_report), cases=cases), indent=2) + '\n')
        print(json.dumps(dict(cases=len(cases), capacitySafeCases=sum(c['safeChorusCapacity'] for c in cases))))
    finally:
        if page: k.VirtualFree(page, 0, 0x8000)
        k.FreeLibrary(module)


if __name__ == '__main__': main()
