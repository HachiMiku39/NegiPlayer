"""Call the user's Sony MMLib11.dll with 32-bit Python on Windows.

Input: raw signed 16-bit little-endian PCM, stereo, 44100 Hz.
Output: an opaque SMFMF blob and optional JSON with known fields.
No network, COM registration, music tag writes, or installer execution.

Interface reference:
https://github.com/superwilso/flint/blob/main/crates/sensme-helper/src/engine.rs
https://github.com/superwilso/Cinder/blob/main/analysis/RE_sensme_musiccenter.md

This adapter is original code. Sony's algorithm remains inside the supplied DLL.
This copy was checked statically on macOS, not executed on Windows.
"""
import argparse
import ctypes as C
import json
from pathlib import Path
import struct
import sys
import uuid


def chunks(blob):
    result, at, bpm = [], 0, None
    while at < len(blob):
        if len(blob) - at < 20:
            raise ValueError('Incomplete SMFMF chunk header')
        size = int.from_bytes(blob[at+16:at+20], 'big')
        if size > len(blob) - at - 20:
            raise ValueError('SMFMF chunk exceeds result bounds')
        name = blob[at:at+4].decode('ascii', 'replace')
        result.append({'name': name, 'bytes': size})
        if name == 'GBPM' and size == 4:
            bpm = struct.unpack('>f', blob[at+20:at+24])[0]
        at += 20 + size
    if not result:
        raise ValueError('Empty SMFMF result')
    return result, bpm


def analyse(dll_path, pcm_path):
    if sys.platform != 'win32' or C.sizeof(C.c_void_p) != 4:
        raise RuntimeError('Use 32-bit Python on Windows; this DLL is x86 Windows COM.')
    H = C.c_long
    P = C.c_void_p
    U = C.c_uint32
    W = C.c_uint16

    class GUID(C.Structure):
        _fields_ = [('bytes', C.c_ubyte * 16)]

    def guid(text):
        return GUID.from_buffer_copy(uuid.UUID(text).bytes_le)

    class Value(C.Union):
        _fields_ = [('i64', C.c_int64), ('i32', C.c_int32), ('ptr', P)]

    class Variant(C.Structure):
        _anonymous_ = ('value',)
        _fields_ = [('vt', W), ('r1', W), ('r2', W), ('r3', W), ('value', Value)]

    assert C.sizeof(Variant) == 16
    ole = C.WinDLL('ole32')
    auto = C.WinDLL('oleaut32')
    kernel = C.WinDLL('kernel32', use_last_error=True)
    ole.CoInitializeEx.argtypes, ole.CoInitializeEx.restype = [P, U], H
    ole.CoUninitialize.argtypes, ole.CoUninitialize.restype = [], None
    auto.VariantClear.argtypes, auto.VariantClear.restype = [C.POINTER(Variant)], H
    auto.SysStringLen.argtypes, auto.SysStringLen.restype = [P], U
    auto.SafeArrayGetDim.argtypes, auto.SafeArrayGetDim.restype = [P], U
    auto.SafeArrayGetElemsize.argtypes, auto.SafeArrayGetElemsize.restype = [P], U
    for name in ('SafeArrayGetLBound', 'SafeArrayGetUBound'):
        fn = getattr(auto, name)
        fn.argtypes, fn.restype = [P, U, C.POINTER(C.c_int32)], H
    auto.SafeArrayAccessData.argtypes, auto.SafeArrayAccessData.restype = [P, C.POINTER(P)], H
    auto.SafeArrayUnaccessData.argtypes, auto.SafeArrayUnaccessData.restype = [P], H
    kernel.LoadLibraryW.argtypes, kernel.LoadLibraryW.restype = [C.c_wchar_p], P
    kernel.GetProcAddress.argtypes, kernel.GetProcAddress.restype = [P, C.c_char_p], P
    kernel.FreeLibrary.argtypes, kernel.FreeLibrary.restype = [P], C.c_int

    def checked(hr, label):
        if hr < 0:
            raise RuntimeError(f'{label} failed: HRESULT 0x{hr & 0xffffffff:08x}')

    def method(obj, index, result, *args):
        vtable = C.cast(obj, C.POINTER(C.POINTER(P))).contents
        return C.WINFUNCTYPE(result, P, *args)(vtable[index])

    checked(ole.CoInitializeEx(None, 2), 'CoInitializeEx')
    module = None
    factory, analysis, result = P(), P(), P()
    try:
        module = kernel.LoadLibraryW(str(dll_path))
        if not module:
            raise C.WinError(C.get_last_error())
        address = kernel.GetProcAddress(module, b'DllGetClassObject')
        if not address:
            raise RuntimeError('DLL has no DllGetClassObject')
        get_class = C.WINFUNCTYPE(H, C.POINTER(GUID), C.POINTER(GUID), C.POINTER(P))(address)
        cls = guid('8DE9ED2D-8CFB-4B33-B8E3-CEE06F2903E3')
        iid_factory = guid('00000001-0000-0000-C000-000000000046')
        iid_analysis = guid('0959C485-A191-4508-A338-9E2B3813A166')
        checked(get_class(C.byref(cls), C.byref(iid_factory), C.byref(factory)), 'DllGetClassObject')
        if not factory:
            raise RuntimeError('DllGetClassObject returned no class factory')
        create = method(factory, 3, H, P, C.POINTER(GUID), C.POINTER(P))
        checked(create(factory, None, C.byref(iid_analysis), C.byref(analysis)), 'CreateInstance')
        if not analysis:
            raise RuntimeError('CreateInstance returned no analysis object')

        version = None
        get_param = method(analysis, 14, H, C.c_int32, C.POINTER(Variant))
        v = Variant()
        try:
            if get_param(analysis, 3, C.byref(v)) >= 0 and v.vt == 8 and v.ptr:
                version = C.wstring_at(v.ptr, auto.SysStringLen(v.ptr))
        finally:
            auto.VariantClear(C.byref(v))

        set_format = method(analysis, 16, H, W, U, W)
        checked(set_format(analysis, 2, 44100, 16), 'SetInputPCMFormat')
        checked(method(analysis, 7, H)(analysis), 'Run')
        feed = method(analysis, 15, H, P, U, C.c_int32, C.c_int32)
        size = pcm_path.stat().st_size
        if size == 0 or size % 4:
            raise ValueError('PCM must contain whole, nonempty 4-byte stereo frames')
        total = 0
        with pcm_path.open('rb') as f:
            current = f.read(16384)
            while current:
                following = f.read(16384)
                buf = C.create_string_buffer(current)
                checked(feed(analysis, buf, len(current), int(not following), 0), 'InputPCM')
                total += len(current)
                current = following
        get_result = method(analysis, 17, H, C.POINTER(P))
        checked(get_result(analysis, C.byref(result)), 'GetResult')
        if not result:
            raise RuntimeError('GetResult returned no result object')
        by_id = method(result, 8, H, C.c_int32, C.POINTER(Variant))
        values = {}
        for index in range(89):
            v = Variant()
            try:
                if by_id(result, index, C.byref(v)) >= 0 and v.vt in (3, 22):
                    values[str(index)] = v.i32
            finally:
                auto.VariantClear(C.byref(v))

        v = Variant()
        try:
            checked(by_id(result, 89, C.byref(v)), 'GetResultByID(89)')
            if v.vt != 0x2011 or not v.ptr:
                raise RuntimeError(f'Result 89 is not a byte SAFEARRAY (vt=0x{v.vt:x})')
            sa = v.ptr
            if auto.SafeArrayGetDim(sa) != 1 or auto.SafeArrayGetElemsize(sa) != 1:
                raise RuntimeError('Unexpected SAFEARRAY shape')
            low, high, ptr = C.c_int32(), C.c_int32(), P()
            checked(auto.SafeArrayGetLBound(sa, 1, C.byref(low)), 'SafeArrayGetLBound')
            checked(auto.SafeArrayGetUBound(sa, 1, C.byref(high)), 'SafeArrayGetUBound')
            count = high.value - low.value + 1
            if not 0 < count <= 16 * 1024 * 1024:
                raise RuntimeError('Unexpected result size')
            checked(auto.SafeArrayAccessData(sa, C.byref(ptr)), 'SafeArrayAccessData')
            try:
                blob = C.string_at(ptr, count)
            finally:
                auto.SafeArrayUnaccessData(sa)
        finally:
            auto.VariantClear(C.byref(v))
        frames = total // 4
        parts, bpm = chunks(blob)
        return blob, {'engine_version': version, 'frames': frames, 'seconds': frames / 44100,
                      'bytes': len(blob), 'bpm': bpm, 'chunks': parts,
                      'integer_result_ids': values}
    finally:
        for obj in (result, analysis, factory):
            if obj:
                method(obj, 2, U)(obj)
        if module:
            kernel.FreeLibrary(module)
        ole.CoUninitialize()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll', type=Path, required=True)
    p.add_argument('--pcm', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--json', type=Path)
    args = p.parse_args()
    dll, pcm = args.dll.resolve(strict=True), args.pcm.resolve(strict=True)
    outputs = [args.out.resolve()] + ([args.json.resolve()] if args.json else [])
    if len(set(outputs)) != len(outputs) or any(x in (dll, pcm) for x in outputs):
        p.error('Input and output paths must be distinct')
    if any(x.exists() for x in outputs):
        p.error('Output already exists; choose new output names')
    blob, summary = analyse(dll, pcm)
    args.out.write_bytes(blob)
    if args.json:
        args.json.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding='utf-8')
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'Error: {exc}', file=sys.stderr)
        raise SystemExit(1)
