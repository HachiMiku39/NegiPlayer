"""Self-generated, exactly representable tempo-stage inputs; no music/model data."""
import array


def make(case, frames, segments):
    if case not in range(4) or not 128<=frames<=38016 or frames%128:
        raise ValueError('Invalid synthetic tempo case')
    patterns=[[320,640,321,160,319,318,0,642,322],
              [271,542,270,135,272,541,540,269,543],
              [0]*9,[1022,511,1021,510,255,1023,1024,512,256]]
    candidates=[patterns[case][i%9] for i in range(segments*3)]
    onsets=array.array('f');seed=0x39BEEFBF
    for band in range(3):
        for i in range(frames):
            seed=(1664525*seed+1013904223)&0xffffffff
            if case==2:value=0
            elif case==3:value=4096 if (i+band)%5==0 else 0
            else:value=((seed>>24)&127)/256+(12 if i%(43+case*7+band)<2 else 0)+(i%97)/64
            onsets.append(value)
    stats=array.array('f');seed=0x39DEC0DE
    bases=[65536,0,0,65536,0,0,0,0,1024,10240,32768,32768,32768,8192,512,4096]
    for block in range(frames//128):
        for column in range(32):
            seed=(1664525*seed+1013904223)&0xffffffff;stream=column%16
            if case==2:value=0
            elif column<16:
                value=((seed>>24)&31)/268435456 if 4<=stream<=7 else (bases[stream]+((seed>>24)&127)-64)/65536
            else:
                value=((seed>>24)&31)/16777216 if 4<=stream<=7 else 0 if stream==3 else (512+((seed>>24)&127))/65536
            stats.append(value)
    return candidates,onsets,stats
