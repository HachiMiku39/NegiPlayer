"""Generated section metadata and spectral statistics for chorus-model tests."""
import array

KINDS=['zero','constant','random','sparse','transient','large']
LABELS=['none','one','tail','repeats2','repeats3','uneven','alternating']
COUNTS=[72,240,960]


def inputs(kind,pattern,count):
    if kind not in KINDS or pattern not in LABELS:raise ValueError('Unknown generated input')
    times=array.array('f',(31.25+i*(250 if count>480 else 500) for i in range(count)))
    labels=array.array('i')
    for i in range(count):
        if pattern=='none':label=-1
        elif pattern=='one':label=0
        elif pattern=='tail':label=0 if 4<=i<count-8 else -1
        elif pattern=='repeats2':label=(i//16)%2
        elif pattern=='repeats3':label=[-1,0,1,2][(i//13)%4]
        elif pattern=='uneven':label=[0,1,2,-1,1,0][(i//7)%6]
        else:label=i%2
        labels.append(label)
    types=max(labels)+1;block_count={72:64,240:160,960:297}[count]
    seed=0x39c407a1;blocks=array.array('f')
    for block in range(block_count):
        for column in range(32):
            seed=(1664525*seed+1013904223)&0xffffffff
            value=64 if kind=='constant' else (seed>>16)&255
            if kind=='zero' or (kind=='sparse' and block%7<4):value=0
            if column%16 in [4,5,6,7]:divisor=16777216
            else:divisor=256 if column<16 else 1024
            result=value/divisor
            if column==3 and kind!='zero':result=1
            if column==5 and kind=='transient':result=(block%4+1)/2048
            if column==17 and kind=='large':result=(block%4+1)*2
            blocks.append(result)
    return times,labels,types,blocks,block_count
