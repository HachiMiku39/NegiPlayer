"""Generate original classifier scores from synthetic prepared features only."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe_integer_fir_windows import AUDITED_SHA256
from synthetic_classifier_input import inputs, stress_inputs


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll', type=Path, required=True); p.add_argument('--out', type=Path, required=True)
    p.add_argument('--feature-oracle', type=Path, help='Also classify previous generated final-feature cases')
    p.add_argument('--stress', type=int, default=0, help='Additional deterministic synthetic cases')
    p.add_argument('--prepared-cases', type=Path, help='Private prepared features; output stays private')
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
        code = b'\x53\x8b\x4c\x24\x08\x8b\x54\x24\x0c\x8b\x5c\x24\x10\xb8' + struct.pack('<I', module + 0x17cd0) + b'\xff\xd0\x5b\xc3'
        control_code = b'\x8b\x44\x24\x04\xd9\x38\xc3'
        allocation_size = len(code) + len(control_code)
        page = k.VirtualAlloc(None, allocation_size, 0x3000, 4)
        if not page: raise C.WinError(C.get_last_error())
        C.memmove(page, code + control_code, allocation_size); old = C.c_uint32()
        if not k.VirtualProtect(page, allocation_size, 0x20, C.byref(old)): raise C.WinError(C.get_last_error())
        k.FlushInstructionCache(k.GetCurrentProcess(), page, allocation_size)
        run = C.CFUNCTYPE(C.c_uint32, C.c_void_p, C.c_void_p, C.c_int32)(page)
        read_control = C.CFUNCTYPE(None, C.POINTER(C.c_uint16))(page + len(code))
        control = C.c_uint16(); read_control(C.byref(control))
        cases = list(inputs())
        if args.feature_oracle:
            source = json.loads(args.feature_oracle.read_text())
            if source['realInput']: raise ValueError('Public classifier oracle must use generated features only')
            for case in source['cases']:
                cases.append(dict(kind='collected', featureKind=case['kind'], pattern=case['pattern'], count=case['count'], words=case['words']))
        if args.stress < 0: raise ValueError('Stress count must be nonnegative')
        cases.extend(stress_inputs(args.stress))
        if args.prepared_cases:
            cases.extend(json.loads(args.prepared_cases.read_text())['cases'])
        selectors = list(range(25, 75))
        for case in cases:
            context = (C.c_uint32 * (0x308 // 4))(); state = (C.c_uint32 * (0xcf8 // 4))()
            context[3] = C.addressof(state); C.memmove(C.addressof(context) + 0x10, (C.c_uint32 * 189)(*case['words']), 756)
            before = bytes(context); result = []
            for selector in selectors:
                output = C.c_uint32(0xa5a5a5a5); status = run(context, C.byref(output), selector)
                if status: raise RuntimeError(('Unsupported selector', selector, status))
                result.append(output.value)
            if bytes(context) != before: raise RuntimeError('Classifier changed caller input')
            case.update(outputWords=result, outputSHA256=hashlib.sha256(struct.pack('<' + str(len(result)) + 'I', *result)).hexdigest())
        args.out.write_text(json.dumps(dict(schemaVersion=1, dllSHA256=AUDITED_SHA256, fpuControlWord=hex(control.value), realInput=bool(args.prepared_cases), selectors=selectors, cases=cases), indent=2) + '\n')
        print(json.dumps(dict(cases=len(cases), scores=len(cases) * len(selectors))))
    finally:
        if page: k.VirtualFree(page, 0, 0x8000)
        k.FreeLibrary(module)


if __name__ == '__main__': main()
