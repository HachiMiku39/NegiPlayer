#!/usr/bin/env python3
"""Original artwork, timed lyrics and header-only ISO fixtures; no user music required."""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import zlib

parser = argparse.ArgumentParser()
parser.add_argument('codec_corpus', type=Path, help='Output of generate-fixtures.py')
parser.add_argument('destination', type=Path)
args = parser.parse_args()
wav = args.codec_corpus / '01 PCM Verification.wav'
if not wav.is_file():
    parser.error('Generate the original codec corpus first')
ffmpeg = shutil.which('ffmpeg')
if not ffmpeg:
    parser.error('FFmpeg is required only for generating verification fixtures')
args.destination.mkdir(parents=True, exist_ok=True)

def png(path, pink=False):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = bytearray()
    for y in range(512):
        rows.append(0)
        for x in range(512):
            band = 130 < x < 190 or 230 < x < 290 or 330 < x < 390
            r, g, b = ((210, 75, 137) if pink else (30, 190, 179)) if band and 140 < y < 390 else (12 + y // 16, 40 + x // 12, 54 + y // 10)
            rows.extend((r, g, b))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 512, 512, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))

for label, name, codec, embedded, pink in [
    ('01 Listening Study', 'Miku Teal Study.flac', 'flac', True, False),
    ('02 Folder Study', 'No Lyrics.wav', None, False, True),
    ('03 ID3 Study', 'ID3 Cover Study.mp3', 'libmp3lame', True, True),
    ('04 ALAC Study', 'ALAC Cover Study.m4a', 'alac', True, False),
]:
    folder = args.destination / label
    folder.mkdir(exist_ok=True)
    cover = folder / 'Cover.png'
    png(cover, pink)
    destination = folder / name
    if codec is None:
        shutil.copyfile(wav, destination)
    else:
        subprocess.run([ffmpeg, '-nostdin', '-loglevel', 'error', '-y', '-i', str(wav), '-i', str(cover),
                        '-map', '0:a', '-map', '1:v', '-c:a', codec, '-c:v', 'copy', '-disposition:v', 'attached_pic',
                        '-metadata', 'title=' + destination.stem, '-metadata', 'artist=NegiPlayer Original Signal',
                        '-metadata', 'album=' + label, '-metadata:s:v', 'title=Front cover',
                        '-metadata:s:v', 'comment=Cover (front)', str(destination)], check=True)
    if embedded:
        cover.unlink()  # Exercise actual embedded readers rather than a folder fallback.
    if label.startswith('01'):
        lyrics = ['初音ミク · Original listening study', '音乐留在原处', 'Cover, controls, and a shared clock',
                  '歌词随着时间滚动', 'Click a line to seek', 'Miku teal and pink', 'é · 日本語 · 🌱',
                  'Read the adjacent LRC', 'No source files are rewritten', 'End of this original test signal']
        destination.with_suffix('.lrc').write_text('[offset:200]\n' + '\n'.join(f'[00:{i*3:02d}.000]{line}' for i, line in enumerate(lyrics)) + '\n', encoding='utf-8')

images = args.destination / '05 Disc Images'
images.mkdir(exist_ok=True)
sacd = bytearray(511 * 2048)
sacd[510 * 2048:510 * 2048 + 8] = b'SACDMTOC'
(images / 'Header-only SACD.iso').write_bytes(sacd)
data_iso = bytearray(17 * 2048)
data_iso[16 * 2048:16 * 2048 + 7] = b'\x01CD001\x01'
(images / 'Header-only Data.iso').write_bytes(data_iso)
(images / 'Invalid.iso').write_bytes(b'Invalid verification fixture')
print('Generated original covers/audio/LRC and non-playable header-only ISO fixtures')
