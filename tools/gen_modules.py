#!/usr/bin/env python3
"""Generates audible ProTracker MOD and FastTracker XM modules for testing."""
import struct, sys

def square_sample(n=256, amp=60):
    half = n // 2
    return bytes([(128 + amp) % 256] * half + [(128 - amp) % 256] * (n - half))

PT_PERIODS = {
    'C-2': 428, 'D-2': 382, 'E-2': 340, 'F-2': 320, 'G-2': 286, 'A-2': 254,
}

def make_mod(path):
    melody = ['C-2', 'E-2', 'G-2', 'C-2', 'F-2', 'A-2', 'C-2', 'G-2'] * 4

    def note(period, sample=1, effect=0xC, param=0x40):
        # b0 = sample_bit4 | period_hi_nibble, b1 = period_lo
        # b2 = (sample_low_nibble << 4) | effect, b3 = param
        return bytes([(sample & 0x10) | ((period >> 8) & 0x0F),
                      period & 0xFF,
                      ((sample & 0x0F) << 4) | (effect & 0x0F),
                      param])

    rows = []
    for i, name in enumerate(melody):
        ch0 = note(PT_PERIODS[name])
        ch1 = note(PT_PERIODS['C-2'], effect=0, param=0) if i % 4 == 0 else b'\x00\x00\x00\x00'
        rows.append(ch0 + ch1 + b'\x00\x00\x00\x00' * 2)
    while len(rows) < 64:
        rows.append(b'\x00' * 16)

    insts = b''
    for _ in range(31):
        insts += (b'testsquare'.ljust(22, b'\x00') +
                  struct.pack('>H', len(square_sample())) +
                  bytes([0, 64]) + struct.pack('>HH', 0, 0))
    data = (b'AC test mod'.ljust(20, b'\x00') + insts +
            bytes([1, 0]) + bytes([0] * 128) + b'M.K.' +
            b''.join(rows) + square_sample())
    with open(path, 'wb') as f:
        f.write(data)
    print('mod:', path, len(data), 'bytes')

# ---------------- XM (FastTracker II, v0104, 2ch) ----------------

def xm_column(sample=1, volume=0x50):
    # bit7 = packed marker; bit0=note, bit1=instrument, bit2=volume follow
    return bytes([0x80 | 0x01 | 0x02 | 0x04, 48, sample, volume])  # note 48 = C-4

EMPTY_COLUMN = bytes([0x80])

def make_xm(path):
    rows = []
    seq = [0, 4, 7, 12, 7, 4]
    for rep in range(8):
        for semi in seq:
            cols = [xm_column(volume=0x50), EMPTY_COLUMN]
            rows.append(b''.join(cols))
    while len(rows) % 64 != 0 or len(rows) == 0:
        rows.append(EMPTY_COLUMN * 2)
    packed = b''.join(rows[:64])
    patterns = struct.pack('<IBHH', 9, 0, 64, len(packed)) + packed

    sample_data_len = 512
    raw = square_sample(sample_data_len)
    signed = [b - 128 for b in raw]
    delta = bytearray()
    prev = 0
    for b in signed:
        prev += b
        delta.append(prev & 0xFF)

    extra_header = (struct.pack('<I', 40) +          # sample header size
                    bytes(96) +                       # note -> sample map
                    bytes(48) +                       # volume envelope points (24x u16)
                    bytes(48) +                       # panning envelope points (24x u16)
                    bytes([0] * 14) +                 # node counts, loops, flags, vibrato
                    struct.pack('<H', 0) +            # fadeout
                    struct.pack('<H', 0))             # reserved
    assert len(extra_header) == 214
    sample_header = struct.pack('<IIIBBbBbB22s',
                                sample_data_len, 0, 0,
                                64,      # volume
                                0,       # finetune
                                0,       # type: 8-bit, no loop
                                128,     # panning centre
                                0,       # relative note
                                0,       # reserved
                                b'testsq'.ljust(22, b'\x00'))
    assert len(sample_header) == 40
    instrument = (struct.pack('<I', 29 + 214) +
                  b'testins'.ljust(22, b'\x00') +
                  bytes([0]) +               # type
                  struct.pack('<H', 1) +     # num samples
                  extra_header +
                  sample_header +
                  bytes(delta))

    header = (b'Extended Module: ' + b'ac test xm'.ljust(20, b'\x00') +
              b'\x1a' + b'AudioCommander'.ljust(20, b'\x00') +
              struct.pack('<H', 0x0104) +
              struct.pack('<I', 276) +
              struct.pack('<HHHHH', 1, 0, 2, 1, 1) +
              struct.pack('<HHH', 1, 6, 125) +
              bytes([0] * 256))
    with open(path, 'wb') as f:
        f.write(header + patterns + instrument)
    print('xm:', path, len(header + patterns + instrument), 'bytes')

if __name__ == '__main__':
    d = sys.argv[1] if len(sys.argv) > 1 else '.'
    make_mod(d + '/loud.mod')
    make_xm(d + '/loud.xm')
