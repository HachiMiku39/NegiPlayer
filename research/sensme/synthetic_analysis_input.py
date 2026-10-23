"""Deterministic integer stereo PCM for complete-analysis boundary tests."""
import struct


def make(spec):
    count = spec['frames']
    leading = spec.get('leadingZeroFrames', 0)
    kind = spec['kind']
    if not 1 <= count <= 44100 * 330 or not 0 <= leading <= count:
        raise ValueError('Generated analysis extent is outside test limits')
    period = 22050 if kind == 'pulse' else 4096
    pattern, seed = bytearray(), 0x39a17c11
    for i in range(period):
        seed = (1664525 * seed + 1013904223) & 0xffffffff
        left = (seed >> 16) - 32768
        seed = (1664525 * seed + 1013904223) & 0xffffffff
        right = (seed >> 16) - 32768
        if kind == 'silence':
            left = right = 0
        elif kind == 'antiphase':
            left = max(-32767, left)
            right = -left
        elif kind == 'pulse':
            left = right = (32 - i) * 1000 if i < 32 else 0
        elif kind == 'triangles':
            left = right = sum((abs(i % p - p // 2) * 4 - p) * 3000 // p
                               for p in [200, 500, 1000])
        elif kind != 'noise':
            raise ValueError(kind)
        pattern.extend(struct.pack('<hh', left, right))
    body = (count - leading) * 4
    return bytes(leading * 4) + (pattern * ((body + len(pattern) - 1) // len(pattern)))[:body]
