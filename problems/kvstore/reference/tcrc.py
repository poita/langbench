"""CRC-32 as defined in SPEC.md §3.

Reflected polynomial 0xEDB88320, initial value 0xFFFFFFFF, reflected input and
output, final XOR of 0xFFFFFFFF. Implemented from scratch: a bit-at-a-time
definition plus a slice-by-four table version used for the bulk work.
"""

from struct import unpack_from


def crc32_slow(data):
    """The bit-at-a-time definition of SPEC.md §3, kept so that the table-driven
    version below can be checked against the specification directly."""
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xEDB88320
            else:
                crc >>= 1
    return crc ^ 0xFFFFFFFF


def _build_tables():
    t0 = []
    for i in range(256):
        c = i
        for _ in range(8):
            if c & 1:
                c = (c >> 1) ^ 0xEDB88320
            else:
                c >>= 1
        t0.append(c)
    tables = [t0]
    for k in range(1, 4):
        prev = tables[k - 1]
        tables.append([(prev[i] >> 8) ^ t0[prev[i] & 0xFF] for i in range(256)])
    return tables


_T0, _T1, _T2, _T3 = _build_tables()


def crc32(data):
    """CRC-32 of a bytes-like object, four bytes per iteration.

    The leading whole words are unpacked in one call, which costs far less than
    slicing the buffer four bytes at a time; the tail falls back to the
    byte-at-a-time table step.
    """
    c = 0xFFFFFFFF
    t0, t1, t2, t3 = _T0, _T1, _T2, _T3
    n = len(data)
    quads = n & ~3
    if quads:
        for w in unpack_from("<%dI" % (quads >> 2), data, 0):
            c ^= w
            c = t3[c & 0xFF] ^ t2[(c >> 8) & 0xFF] ^ t1[(c >> 16) & 0xFF] ^ t0[(c >> 24) & 0xFF]
    for i in range(quads, n):
        c = t0[(c ^ data[i]) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF
