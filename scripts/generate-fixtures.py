#!/usr/bin/env python3
"""Generate original verification audio, not user music. FFmpeg is a test tool only."""
import argparse
import math
from pathlib import Path
import shutil
import struct
import subprocess
import wave

parser = argparse.ArgumentParser()
parser.add_argument('destination', type=Path)
args = parser.parse_args()
args.destination.mkdir(parents=True, exist_ok=True)
wav = args.destination / '01 PCM Verification.wav'
rate, seconds = 44100, 30
with wave.open(str(wav), 'wb') as f:
    f.setnchannels(2); f.setsampwidth(2); f.setframerate(rate)
    # Very low-level original signal. Silence sections test timeline positioning.
    for block in range(seconds):
        f.writeframes(b''.join(struct.pack('<hh', *( [int(16 * math.sin(2*math.pi*440*(block*rate+i)/rate))]*2 )) for i in range(rate)))

ffmpeg = shutil.which('ffmpeg')
if ffmpeg:
    for name, codec in [('02 MP3 Verification.mp3','libmp3lame'),('03 FLAC Verification.flac','flac'),('04 AAC Verification.m4a','aac'),('05 ALAC Verification.m4a','alac')]:
        subprocess.run([ffmpeg, '-nostdin', '-loglevel', 'error', '-y', '-i', str(wav), '-c:a', codec,
                        '-metadata','title='+name.split(' ',1)[1].rsplit('.',1)[0], '-metadata','artist=NegiPlayer Test Signal',
                        '-metadata','album=Codec Verification', '-metadata','album_artist=NegiPlayer Test Signal',
                        str(args.destination / name)], check=True)

dsd_rate, samples = 2822400, 2822400
payload_length = ((samples//8+4095)//4096)*4096*2
fmt = b'fmt '+struct.pack('<QIIIIIIQII',52,1,0,2,2,dsd_rate,1,samples,4096,0)
dsf = b'DSD '+struct.pack('<QQQ',28,28+len(fmt)+12+payload_length,0)+fmt+b'data'+struct.pack('<Q',12+payload_length)+bytes([0x69])*payload_length
(args.destination / '06 DSD64 Verification.dsf').write_bytes(dsf)

def iff_chunk(name, payload):
    return name+struct.pack('>Q',len(payload))+payload+(b'\0' if len(payload)%2 else b'')
prop = b'SND '+iff_chunk(b'FS  ',struct.pack('>I',dsd_rate))+iff_chunk(b'CHNL',struct.pack('>H',2)+b'SLFTSRGT')+iff_chunk(b'CMPR',b'DSD '+bytes([14])+b'not compressed')
body = b'DSD '+iff_chunk(b'FVER',struct.pack('>I',0x01050000))+iff_chunk(b'PROP',prop)+iff_chunk(b'DSD ',bytes([0x69])*(samples//8*2))
(args.destination / '07 Raw DFF Verification.dff').write_bytes(b'FRM8'+struct.pack('>Q',len(body))+body)

(args.destination / 'verification.lrc').write_text('[00:00.000001]  <00:00.000001>初<00:02.123456>音、<00:04.000001>ミク！\n[00:06.000000]NegiPlayer 逐字打轴\n',encoding='utf-8')
print('Generated original WAV/MP3/FLAC/AAC/ALAC/DSF/raw DFF samples in',args.destination)
print('DSF/DFF are valid synthetic DSD silence containers; no DST compressed sample is claimed.')
