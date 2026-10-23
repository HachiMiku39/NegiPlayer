"""Generated beat-class/section-label input, independent of songs and models."""
CLASS_KINDS=['zero','minor','ramp','random','triad','cycle']
SECTION_KINDS=['one','every7','alternating','reused']
COUNTS=[1,17,960]


def make(kind,section_kind,count):
    seed=0x39ca7e11;classes=[];sections=[]
    if kind not in CLASS_KINDS or section_kind not in SECTION_KINDS:raise ValueError('Unknown generated input')
    for i in range(count):
        seed=(1664525*seed+1013904223)&0xffffffff
        if kind=='zero':value=0
        elif kind=='minor':value=12
        elif kind=='ramp':value=i%24
        elif kind=='random':value=(seed>>16)%24
        elif kind=='triad':value=[0,4,7,12,16,19][i%6]
        else:value=[0,7,5,14,17,21,9][(i//5)%7]
        label=0 if section_kind=='one' else i//7 if section_kind=='every7' else i%2-1 if section_kind=='alternating' else [2,-1,2,3][(i//13)%4]
        classes.append(value);sections.append(label)
    return classes,sections
