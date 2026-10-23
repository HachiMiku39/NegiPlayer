"""Generated prepared-feature words, independent of any source music."""
import struct


def inputs():
    seed = 0x39cf17cd
    offsets = [0x98, 0x9c, 0xa0, 0xa4, 0xa8, 0xac] + list(range(0xb0, 0xf0, 4)) + list(range(0x1c0, 0x2e0, 4)) + [0x2e8, 0x2f0, 0x2f4, 0x2f8]
    for case in range(80):
        words = [0] * 189
        for offset in offsets:
            seed = (1664525 * seed + 1013904223) & 0xffffffff
            value = case if case < 16 else (seed >> 16) % 255 if case < 48 else (seed >> 16) % 1001 - 500
            words[(offset - 0x10) // 4] = value & 0xffffffff
        yield dict(kind='generated', case=case, words=words)


def stress_inputs(count=2048):
    seed = 0x39cf5050
    offsets = [0x98, 0x9c, 0xa0, 0xa4, 0xa8, 0xac] + list(range(0xb0, 0xf0, 4)) + list(range(0x1c0, 0x2e0, 4)) + [0x2e8, 0x2f0, 0x2f4, 0x2f8]
    for case in range(count):
        words = [0] * 189
        for offset in offsets:
            seed = (1664525 * seed + 1013904223) & 0xffffffff
            group = case % 4
            value = ((seed >> 16) % 255 - 128 if group == 0 else
                     (seed >> 8) % 10001 - 5000 if group == 1 else
                     seed if group == 2 else (seed >> 16) % 101)
            words[(offset - 0x10) // 4] = value & 0xffffffff
        bpm = struct.unpack('<f', struct.pack('<f', 30 + seed % 270000 / 1000))[0]
        words[(0x2e0 - 0x10) // 4:(0x2e0 - 0x10) // 4 + 2] = struct.unpack('<II', struct.pack('<d', bpm))
        yield dict(kind='stress', case=case, words=words)
