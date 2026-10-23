"""Generated beat/key/statistical inputs for final feature collection."""
import struct

KINDS = ['zero', 'constant', 'random', 'cycle', 'wide']
PATTERNS = ['none', 'one', 'blocks', 'alternating']
COUNTS = [1, 24, 120, 960]


def make(kind, pattern, count):
    seed = 0x39cf1373
    def next_word():
        nonlocal seed
        seed = (1664525 * seed + 1013904223) & 0xffffffff
        return seed >> 16
    def f(value): return struct.unpack('<f', struct.pack('<f', value))[0]
    beats = bytearray(count * 168)
    for i in range(count):
        cls = next_word() % 24
        if kind == 'constant': cls = 21
        elif kind == 'zero': cls = 0
        elif kind == 'cycle': cls = [0, 5, 7, 0, 21, 2, 4, 21, 14, 16][i % 10]
        root = next_word() % 12
        if kind in ['zero', 'constant', 'cycle']: root = 0
        label = -1 if pattern == 'none' else 0 if pattern == 'one' else i // 16 % 3 if pattern == 'blocks' else i % 2
        struct.pack_into('<fiii', beats, i * 168, f(31.25 + i * (250 if count > 480 else 500)), i // 4, i % 4 + 1, cls)
        struct.pack_into('<i', beats, i * 168 + 112, root)
        struct.pack_into('<i', beats, i * 168 + 164, label)
        for column in range(36):
            value = next_word() / 65536
            if kind == 'zero': value = 0
            elif kind == 'constant': value = 0.5
            offset = 16 + column * 4 if column < 24 else 116 + (column - 24) * 4
            struct.pack_into('<f', beats, i * 168 + offset, f(value))
    summaries = []
    for column in range(128):
        value = next_word() / 65536
        if column % 16 in [4, 5, 6, 7]: value /= 16777216
        if kind == 'zero': value = 0
        elif kind == 'constant': value = 1 if column % 16 not in [4, 5, 6, 7] else 1 / 16777216
        elif kind == 'wide': value *= 8
        summaries.append(f(value))
    return dict(beats=beats, summaries=summaries, bpm=0 if kind == 'zero' else 127.5,
                logBpm=0 if kind == 'zero' else f(3.25), spectrumSpread=0 if kind == 'zero' else f(0.25),
                chorusType=0, chorusBeat=count // 3)
