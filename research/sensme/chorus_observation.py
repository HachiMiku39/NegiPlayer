"""Read-only observation of the audited 1.6.1 chorus call boundaries."""
import ctypes as C
import struct


POINTS=[('chorus_score',0x128c5,0x17340,24),('chorus_probability',0x128db,0x28b3d,12),
        ('chorus_totals',0x12a0e,0x28b3d,12)]


def capture(stage,frame_address,register_address):
    registers=struct.unpack('<8I',C.string_at(register_address,32))
    # PUSHAD runs after the observer thunk establishes its own EBP frame;
    # that frame's saved first word is the original routine's EBP/state.
    state=C.c_uint32.from_address(registers[2]).value
    def u32(offset):return C.c_uint32.from_address(frame_address+offset).value
    version=[C.c_uint32.from_address(state+offset).value for offset in [0x10c,0x110,0x118]]
    if version!=[1,6,1]:raise ValueError(f'Chorus observer requires default 1.6.1: {stage}, observed {version}')
    if stage=='chorus_totals':
        count=C.c_uint32.from_address(state+0x48c).value
        if not 0<count<=99:raise ValueError('Invalid chorus type count')
        return dict(stage=stage,typeScoreBits=list(struct.unpack('<'+'I'*count,C.string_at(u32(0x4c),count*4))),
                    selected=list(struct.unpack('<II',C.string_at(state+0x490,8))))
    record=dict(stage=stage,startBeat=u32(0x50),endBeat=u32(0x34),sectionType=u32(0x28),
                frequencyBits=u32(0xd4),meanPositionBits=u32(0xd8),meanDurationBits=u32(0xdc))
    if stage=='chorus_score':
        data=C.c_uint32.from_address(registers[7]).value
        record.update(rawScoreBits=C.c_uint32.from_address(data).value,
                      summaryBits=list(struct.unpack('<64I',C.string_at(state+0x35c,256))),
                      ratioBits=list(struct.unpack('<64I',C.string_at(frame_address+0x1f0,256))))
    else:record['probabilityBits']=u32(0x38)
    return record
