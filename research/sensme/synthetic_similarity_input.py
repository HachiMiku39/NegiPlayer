"""Generated two-beat descriptor inputs; no music-derived values."""
from synthetic_tonal_input import make

KINDS=['zero','constant','random','triad','near-flat']
COUNTS=[2,4,18,72,326,960]


def inputs(kind,count):
    tones=make(kind)[1]
    step=250 if count>480 else 500
    times=[31.25+i*step for i in range(count)]
    return tones,times
