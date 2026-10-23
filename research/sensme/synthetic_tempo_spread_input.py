"""Music-independent inputs for the logarithmic tempo-spectrum statistic."""
import struct

KINDS = ['zero', 'constant', 'random', 'sparse', 'low', 'high', 'wide']


def spectra(kind, segments):
    seed = 0x39c02746
    for segment in range(segments):
        values = []
        for bin in range(2049):
            seed = (1664525 * seed + 1013904223) & 0xffffffff
            value = ((seed >> 16) & 65535) / 64
            if kind == 'zero': value = 0
            elif kind == 'constant': value = 1
            elif kind == 'sparse' and bin % 53: value = 0
            elif kind == 'low' and bin > 32: value = 0
            elif kind == 'high' and bin < 2000: value = 0
            elif kind == 'wide': value *= 2 ** ((bin % 31) - 15)
            values.append(struct.unpack('<f', struct.pack('<f', value))[0])
        yield values


def profiles():
    for kind in KINDS:
        for count in [1, 3, 10]:
            yield kind, count
