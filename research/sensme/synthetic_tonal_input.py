"""Self-generated compressed tone inputs; contains no music or model data."""
import array

KINDS=['zero','constant','random','ramp','limits','single','triad','near-flat']
RANGES=[(0,2),(0,3),(1,3),(11,33),(99,128),(1234,599),(37999,257),(38016,1),(38015,4),(0,38016)]


def make(kind,pairs=19008):
    if kind not in KINDS:raise ValueError(kind)
    seed=0x39da7a11;groups=[]
    for group in range(2):
        values=array.array('H')
        for pair in range(pairs):
            for tone in range(12):
                seed=(1664525*seed+1013904223)&0xffffffff
                if kind=='zero':value=0
                elif kind=='constant':value=12345+group
                elif kind=='random':value=seed>>16
                elif kind=='ramp':value=(pair*7+tone*361+group*53)&65535
                elif kind=='limits':value=[0,65535,1,32768,65534][(pair+tone+group)%5]
                elif kind=='single':value=60000 if tone==(pair//500+group)%12 else 33
                elif kind=='triad':value=36000 if (tone-pair//1000-group)%12 in [0,4,7] else 1234
                else:value=32768+(seed>>31)
                values.append(value)
        groups.append(values)
    return groups
