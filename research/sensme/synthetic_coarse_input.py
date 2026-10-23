"""Generated peak ridges for repeated-section search; no learned data."""
import array

KINDS=['diagonal','plateau','periodic','three-types','dense','random']
COUNTS=[48,144,480,960]
PHASES=[0,2]


def inputs(kind,count,phase):
    if kind not in KINDS:raise ValueError(kind)
    side=count//2-1;seed=0x39ce7e11;matrix=array.array('H',[0])*(side*side)
    for row in range(side):
        for column in range(row,side):
            seed=(1664525*seed+1013904223)&0xffffffff
            if row==column:value=65535
            elif kind=='diagonal':value=0
            elif kind=='plateau':value=60000
            elif kind=='periodic':value=60000 if (row-column)%32==0 else 1000
            elif kind=='three-types':value=60000 if row//32%3==column//32%3 and row%32==column%32 else 1000
            elif kind=='dense':value=60000 if (row-column)%2==0 else 1000
            else:value=seed>>16
            matrix[row*side+column]=matrix[column*side+row]=value
    return matrix,[(i+phase)%4+1 for i in range(count)]
