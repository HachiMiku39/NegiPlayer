"""Original complete-analysis oracle on generated PCM, with isolated case processes.

Observe the prepared context at the first default formatter call. The loaded
call site is restored; --verify-unobserved compares the entire SMFMF payload.
No music is used. The supplied original DLL remains a research dependency only.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Resources/Enrichment'))
from probe_integer_fir_windows import AUDITED_SHA256
from synthetic_analysis_input import make


def child(dll, spec, out, verify):
    from sensme_analyze_windows import analyse
    if C.sizeof(C.c_void_p) != 4 or hashlib.sha256(dll.read_bytes()).hexdigest() != AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and Windows x86 Python')
    pcm = out.with_suffix('.s16le')
    pcm.write_bytes(make(spec))
    digest = hashlib.sha256(pcm.read_bytes()).hexdigest()
    kernel = C.WinDLL('kernel32', use_last_error=True)
    kernel.LoadLibraryW.argtypes = [C.c_wchar_p]; kernel.LoadLibraryW.restype = C.c_void_p
    kernel.FreeLibrary.argtypes = [C.c_void_p]
    kernel.VirtualAlloc.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.c_uint32]
    kernel.VirtualAlloc.restype = C.c_void_p
    kernel.VirtualProtect.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(C.c_uint32)]
    kernel.VirtualFree.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32]
    kernel.GetCurrentProcess.restype = C.c_void_p
    kernel.FlushInstructionCache.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    module = kernel.LoadLibraryW(str(dll.resolve()))
    if not module: raise C.WinError(C.get_last_error())
    observation, errors = {}, []

    @C.CFUNCTYPE(None, C.c_void_p, C.c_void_p)
    def observe(context, descriptor):
        try:
            state = C.c_uint32.from_address(context + 12).value
            count = C.c_uint32.from_address(state + 0x478).value
            if count > 960: raise ValueError('Beat count exceeds original limit')
            pointer = C.c_uint32.from_address(state + 0x474).value
            words = list(struct.unpack('<189I', C.string_at(context + 0x10, 756)))
            words[(0x2fc - 0x10)//4] = words[(0x300 - 0x10)//4] = 0
            observation.update(words=words, beatsHex=C.string_at(pointer, count * 168).hex() if count else '',
                processedFrames=C.c_uint32.from_address(state + 0x128).value,
                volumeBits=C.c_uint32.from_address(state + 0x154).value,
                bpmBits=C.c_uint32.from_address(state + 0x468).value,
                logBpmBits=C.c_uint32.from_address(state + 0x46c).value,
                spreadBits=C.c_uint32.from_address(state + 0x470).value,
                chorusType=C.c_int32.from_address(state + 0x490).value,
                chorusBeat=C.c_uint32.from_address(state + 0x494).value,
                sampleOffset=C.c_uint32.from_address(descriptor + 20).value)
        except Exception as error:
            errors.append(str(error))

    # At this audited call, EBX is the result context and ECX the descriptor.
    callback = C.cast(observe, C.c_void_p).value
    code = (b'\x9c\x60\x51\x53\xb8' + struct.pack('<I', callback) +
            b'\xff\xd0\x83\xc4\x08\x61\x9d\xe9')
    page = kernel.VirtualAlloc(None, len(code) + 4, 0x3000, 4)
    if not page: raise C.WinError(C.get_last_error())
    code += struct.pack('<I', (module + 0x23260 - (page + len(code) + 4)) & 0xffffffff)
    C.memmove(page, code, len(code)); protection = C.c_uint32()
    if not kernel.VirtualProtect(page, len(code), 0x20, C.byref(protection)):
        raise C.WinError(C.get_last_error())
    kernel.FlushInstructionCache(kernel.GetCurrentProcess(), page, len(code))
    site = module + 0x5d00; original = C.string_at(site, 5); old = C.c_uint32()
    if original[0] != 0xe8 or site + 5 + struct.unpack('<i', original[1:])[0] != module + 0x23260:
        raise ValueError('Audited formatter call site differs')
    if not kernel.VirtualProtect(site, 5, 0x40, C.byref(old)):
        raise C.WinError(C.get_last_error())
    try:
        C.memmove(site, b'\xe8' + struct.pack('<I', (page - site - 5) & 0xffffffff), 5)
        kernel.FlushInstructionCache(kernel.GetCurrentProcess(), site, 5)
        blob, summary = analyse(dll, pcm)
    finally:
        C.memmove(site, original, 5)
        kernel.FlushInstructionCache(kernel.GetCurrentProcess(), site, 5)
        ignored = C.c_uint32(); kernel.VirtualProtect(site, 5, old.value, C.byref(ignored))
        kernel.VirtualFree(page, 0, 0x8000)
        kernel.FreeLibrary(module)
    if errors or not observation: raise RuntimeError(errors or 'Formatter was not observed')
    if verify:
        plain, _ = analyse(dll, pcm)
        if plain != blob: raise RuntimeError('Observation changed complete result')
    if hashlib.sha256(pcm.read_bytes()).hexdigest() != digest:
        raise RuntimeError('Generated input changed')
    pcm.unlink()
    return dict(kind='generated-complete-analysis', spec=spec, pcmSHA256=digest, **observation,
        encodedHex=blob.hex(), encodedBytes=len(blob), encodedSHA256=hashlib.sha256(blob).hexdigest(),
        summary=summary, unobservedVerified=verify)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--verify-unobserved', action='store_true')
    parser.add_argument('--case-index', type=int)
    args = parser.parse_args()
    specs = json.loads(args.input.read_text())['cases']
    if args.case_index is not None:
        result = child(args.dll, specs[args.case_index], args.out, args.verify_unobserved)
        args.out.write_text(json.dumps(result, separators=(',', ':')) + '\n')
        return
    cases = []
    for index, spec in enumerate(specs):
        path = args.out.with_name('generated-analysis-case-' + str(index) + '.json')
        arguments = [sys.executable, str(Path(__file__).resolve()), '--dll', str(args.dll),
                     '--input', str(args.input), '--out', str(path), '--case-index', str(index)]
        if args.verify_unobserved: arguments.append('--verify-unobserved')
        try:
            run = subprocess.run(arguments, capture_output=True, timeout=90)
            if run.returncode or not path.exists():
                raise RuntimeError('Isolated reference failed: ' + str(run.returncode) + '; ' + run.stderr.decode(errors='replace')[-1200:])
            result = json.loads(path.read_text()); path.unlink()
        except Exception as error:
            result = dict(kind='generated-complete-analysis', spec=spec, error=str(error))
        cases.append(result)
        print(json.dumps(dict(case=index, kind=spec['kind'], frames=spec['frames'],
                              bytes=result.get('encodedBytes'), failed='error' in result)), flush=True)
    args.out.write_text(json.dumps(dict(schemaVersion=1, dllSHA256=AUDITED_SHA256,
        realInput=False, cases=cases), separators=(',', ':')) + '\n')


if __name__ == '__main__':
    main()
