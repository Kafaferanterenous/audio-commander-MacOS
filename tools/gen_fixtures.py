#!/usr/bin/env python3
"""Generates minimal-but-valid .voc and .mid fixtures for decoder testing."""
import math, struct, sys

def make_voc(path):
    sr_byte = 131  # 1000000/(256-131) = 8000 Hz
    n = 8000       # 1 second of tone
    data = bytes(int(127.5 + 60 * math.sin(2*math.pi*440*i/8000)) & 0xFF for i in range(n))
    block = bytes([0x01]) + struct.pack('<I', len(data)+2)[0:3] + bytes([sr_byte, 0]) + data
    silence = bytes([0x03]) + struct.pack('<I', 4000)[0:3] + struct.pack('<HB', 4000, sr_byte)
    out = b'Creative Voice File\x1a' + struct.pack('<HHH', 26, 0x0100, 0x1129) + block + silence + b'\x00'
    with open(path,'wb') as f: f.write(out)
    print('voc:', path, len(out), 'bytes; expect ~1.5 s')

def vlq(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        if n: out.append(b | 0x80)
        else: out.append(b); break
    return bytes(out)

def make_mid(path):
    trk = bytearray()
    trk += vlq(0) + bytes([0xC0, 40])            # program change (violin)
    trk += vlq(0) + bytes([0x90, 69, 100])       # note on A4
    trk += vlq(240) + bytes([0x80, 69, 0])       # note off after quarter
    trk += vlq(0) + bytes([0x90, 72, 100])
    trk += vlq(240) + bytes([0x80, 72, 0])
    trk += vlq(240) + bytes([0xFF, 0x2F, 0x00])  # end of track
    mid = (b'MThd' + struct.pack('>IHHH', 6, 0, 1, 480) +
           b'MTrk' + struct.pack('>I', len(trk)) + bytes(trk))
    with open(path,'wb') as f: f.write(mid)
    print('mid:', path, len(mid), 'bytes; expect ~1.0 s')

if __name__ == '__main__':
    d = sys.argv[1] if len(sys.argv) > 1 else '.'
    make_voc(d + '/test.voc')
    make_mid(d + '/test.mid')
