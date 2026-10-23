"""Observe tone projections and onset curves in an owner-supplied DLL.

Runs the audited accumulator on private energy frames in Windows x86 Python.
No call sites or DLL files are modified. Outputs remain at --out-prefix.
"""
import argparse
import array
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
    parser.add_argument('--features', type=Path, required=True)
    parser.add_argument('--out-prefix', type=Path, required=True)
    parser.add_argument('--skip-frames', type=int, default=292)
    parser.add_argument('--max-blocks', type=int, default=297)
    args = parser.parse_args()
    if args.skip_frames < 0 or not 1 <= args.max_blocks <= 297:
        parser.error('Invalid frame range')
    if C.sizeof(C.c_void_p) != 4 or hashlib.sha256(args.dll.read_bytes()).hexdigest() != AUDITED_SHA256:
        raise RuntimeError('Requires audited DLL and Windows x86 Python')
    raw = args.features.read_bytes()
    if len(raw) % 144:
        raise ValueError('Expected 72-column uint16 energy frames')
    blocks = min(args.max_blocks, max(0, (len(raw)//144-args.skip_frames)//128))
    if not blocks:
        raise ValueError('No complete blocks')
    energy = array.array('H'); energy.frombytes(raw)
    kernel = C.WinDLL('kernel32', use_last_error=True)
    kernel.LoadLibraryW.argtypes = [C.c_wchar_p]; kernel.LoadLibraryW.restype = C.c_void_p
    kernel.VirtualAlloc.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.c_uint32]
    kernel.VirtualAlloc.restype = C.c_void_p
    kernel.VirtualProtect.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(C.c_uint32)]
    kernel.VirtualFree.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32]
    kernel.GetCurrentProcess.restype = C.c_void_p
    kernel.FlushInstructionCache.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    module = kernel.LoadLibraryW(str(args.dll.resolve()))
    if not module:
        raise C.WinError(C.get_last_error())
    pages = []
    def thunk(body, prototype):
        # Save all nonvolatile registers across recovered register conventions.
        code = b'\x55\x89\xe5\x53\x56\x57' + body + b'\x5f\x5e\x5b\x89\xec\x5d\xc3'
        page = kernel.VirtualAlloc(None, len(code), 0x3000, 4)
        if not page: raise C.WinError(C.get_last_error())
        pages.append(page); C.memmove(page, code, len(code)); old = C.c_uint32()
        if not kernel.VirtualProtect(page, len(code), 0x20, C.byref(old)):
            raise C.WinError(C.get_last_error())
        kernel.FlushInstructionCache(kernel.GetCurrentProcess(), page, len(code))
        return prototype(page)
    initialize = thunk(b'\x8b\x5d\x08\xb8\x06\x00\x00\x00\x6a\x01\xba'
                       + struct.pack('<I', module+0xb790) + b'\xff\xd2',
                       C.CFUNCTYPE(None, C.c_void_p))
    run = thunk(b'\xb9\x06\x00\x00\x00\x6a\x01\xff\x75\x0c\xff\x75\x08\xb8'
                + struct.pack('<I', module+0xbb20) + b'\xff\xd0',
                C.CFUNCTYPE(None, C.c_void_p, C.c_void_p))
    release_profile = thunk(b'\x8b\x75\x08\xb8'+struct.pack('<I', module+0xc9f0)+b'\xff\xd0',
                            C.CFUNCTYPE(None, C.c_void_p))
    dll_free = C.CFUNCTYPE(None, C.c_void_p)(module+0x28b3d)
    state = (C.c_ubyte*0xcf0)(); address = C.addressof(state)
    record = (C.c_uint32*(0x130//4))(); keep = []
    def u32(offset): return C.c_uint32.from_address(address+offset).value
    def set_u32(offset, value): C.c_uint32.from_address(address+offset).value = value
    set_u32(0x11c, 38016); set_u32(0x124, C.addressof(record))
    for profile in range(2):
        for column in range(32):
            data = (C.c_float*297)(); shape = (C.c_int32*2)(297, 0x10)
            header = (C.c_uint32*5)(C.addressof(data), 297, 1, C.addressof(shape), 0)
            record[(0x0c+profile*0x80)//4+column] = C.addressof(header)
            keep.extend([data, shape, header])
    tones = []
    for offset in [0x110, 0x114, 0x11c]:
        data = (C.c_uint16*(38016//2*12))(); keep.append(data); tones.append(data)
        record[offset//4] = C.addressof(data)
    onsets = []
    for offset in [0x124, 0x128, 0x12c]:
        data = (C.c_float*38016)(); keep.append(data); onsets.append(data)
        record[offset//4] = C.addressof(data)
    try:
        initialize(address)
        report = dict(schemaVersion=1, dllSHA256=AUDITED_SHA256,
                      inputSHA256=hashlib.sha256(raw).hexdigest(), skippedFrames=args.skip_frames,
                      blocks=blocks, onsetWindow=u32(0x134),
                      bandBoundaries=[u32(0x12c), u32(0x130)],
                      onsetWeights=list((C.c_float*72).from_address(u32(0x13c))))
        for block in range(blocks):
            at = (args.skip_frames+block*128)*144
            source = (C.c_uint16*(128*72)).from_buffer(energy, at)
            run(address, source)
            if u32(0x128) != (block+1)*128:
                raise RuntimeError('Accumulator did not accept complete block')
        report['processedFrames'] = u32(0x128)
        report['tones'] = []; report['onsets'] = []
        for group, data in enumerate(tones):
            payload = bytes(data)[:blocks*64*12*2]
            path = Path(str(args.out_prefix)+f'.tone-{group}.u16le'); path.write_bytes(payload)
            report['tones'].append(dict(path=str(path), SHA256=hashlib.sha256(payload).hexdigest()))
        onset_count = max(0, blocks*128-report['onsetWindow'])
        for band, data in enumerate(onsets):
            payload = bytes(data)[:onset_count*4]
            path = Path(str(args.out_prefix)+f'.onset-{band}.f32le'); path.write_bytes(payload)
            report['onsets'].append(dict(path=str(path), SHA256=hashlib.sha256(payload).hexdigest()))
        report['windowSums'] = list((C.c_int32*72).from_address(u32(0x138)))
        report['lastOnsets'] = list((C.c_float*3).from_address(address+0x144))
        Path(str(args.out_prefix)+'.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(dict(blocks=blocks, processed=report['processedFrames'], boundaries=report['bandBoundaries'])))
    finally:
        for offset in [0x45c, 0x460]:
            pointer = u32(offset)
            if pointer: release_profile(pointer); dll_free(pointer)
        for offset in [0x464, 0x138, 0x13c, 0x150]:
            pointer = u32(offset)
            if pointer: dll_free(pointer)
        for page in pages: kernel.VirtualFree(page, 0, 0x8000)


if __name__ == '__main__': main()
