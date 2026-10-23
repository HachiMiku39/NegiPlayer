"""Synthetic oracle for the audited analysis resampler, no playback backend."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe_integer_fir_windows import AUDITED_SHA256, signed_word
from probe_pcm_windows import partitions


def resampler_cases():
    return [44100/7040, 48000/7040, 96000/7040, 192000/7040, 6.0, 1.5, 1.0, 0.75]


def resampler_input(count=262144):
    state = 0x39C0FFEE
    samples = []
    for i in range(count):
        state = (1664525 * state + 1013904223) & 0xffffffff
        word = signed_word(state >> 16)
        if i % 256 == 0: word = -32768
        samples.append(word / 32768.0)
    return samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if C.sizeof(C.c_void_p) != 4 or hashlib.sha256(args.dll.read_bytes()).hexdigest() != AUDITED_SHA256:
        raise RuntimeError("Requires audited DLL and Windows x86 Python")
    k = C.WinDLL("kernel32", use_last_error=True)
    k.LoadLibraryW.argtypes=[C.c_wchar_p]; k.LoadLibraryW.restype=C.c_void_p
    k.VirtualAlloc.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.c_uint32]; k.VirtualAlloc.restype=C.c_void_p
    k.VirtualProtect.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32,C.POINTER(C.c_uint32)]
    k.VirtualFree.argtypes=[C.c_void_p,C.c_size_t,C.c_uint32]
    k.GetCurrentProcess.restype=C.c_void_p
    k.FlushInstructionCache.argtypes=[C.c_void_p,C.c_void_p,C.c_size_t]
    module = k.LoadLibraryW(str(args.dll.resolve()))
    if not module: raise C.WinError(C.get_last_error())
    thunks=[]
    try:
        methods=[]
        for rva in [0x24620,0x246d0]:
            code=(b"\x55\x89\xe5\x8b\x4d\x08\xff\x75\x10\xff\x75\x0c\xba"
                  +struct.pack('<I',module+rva)+b"\xff\xd2\x89\xec\x5d\xc3")
            address=k.VirtualAlloc(None,len(code),0x3000,0x04)
            if not address: raise C.WinError(C.get_last_error())
            thunks.append(address)
            C.memmove(address,code,len(code)); previous=C.c_uint32()
            if not k.VirtualProtect(address,len(code),0x20,C.byref(previous)): raise C.WinError(C.get_last_error())
            k.FlushInstructionCache(k.GetCurrentProcess(),address,len(code))
            methods.append(C.CFUNCTYPE(None,C.c_void_p,C.c_void_p,C.c_int32)(address))
        write,read=methods
        samples=resampler_input()
        results=[]
        for ratio in resampler_cases():
            factor=1; step=ratio
            while step>=2: factor*=2; step*=0.5
            capacity=16384//factor
            ring=(C.c_float*capacity)(); pending=(C.c_float*factor)(); obj=(C.c_ubyte*64)()
            for offset,value in [(0x10,C.addressof(ring)),(0x20,capacity),(0x30,factor),(0x34,C.addressof(pending))]:
                C.c_uint32.from_buffer(obj,offset).value=value
            C.c_double.from_buffer(obj,8).value=ratio
            C.c_double.from_buffer(obj,0x28).value=step
            digest=hashlib.sha256(); frames=0
            def available():
                distance=C.c_uint32.from_buffer(obj,0x14).value-int(C.c_double.from_buffer(obj,0x18).value)
                if distance<0: distance+=capacity
                return int(distance/step)
            for at,count in partitions(len(samples)):
                block=(C.c_float*count)(*samples[at:at+count])
                write(C.byref(obj),block,count)
                count=available()
                if count:
                    out=(C.c_float*count)()
                    read(C.byref(obj),out,count)
                    digest.update(bytes(out)); frames+=count
            pos=C.c_double.from_buffer(obj,0x18).value
            sentinel=(C.c_float*3)(-9,-9,-9)
            read(C.byref(obj),sentinel,3)
            if bytes(sentinel)!=b'\0'*12 or pos!=C.c_double.from_buffer(obj,0x18).value:
                raise AssertionError("Unexpected insufficient-input behavior")
            results.append(dict(ratio=ratio,inputFrames=len(samples),outputFrames=frames,
                                sha256=digest.hexdigest(),finalAvailable=available(),
                                readPosition=pos.hex(),pendingInputFrames=C.c_uint32.from_buffer(obj,0x38).value))
        args.out.write_text(json.dumps(dict(schemaVersion=1,dllSHA256=AUDITED_SHA256,cases=results),indent=2)+"\n")
        print(json.dumps(dict(cases=len(results),syntheticInputFrames=len(samples))))
    finally:
        for thunk in thunks: k.VirtualFree(thunk,0,0x8000)


if __name__=='__main__': main()
