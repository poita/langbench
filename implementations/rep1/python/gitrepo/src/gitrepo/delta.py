"""Git delta application (the ``OFS_DELTA`` / ``REF_DELTA`` payload format)."""

from __future__ import annotations

from .errors import CorruptObjectError


def _read_size(delta: bytes, pos: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while True:
        if pos >= len(delta):
            raise CorruptObjectError("truncated delta header")
        byte = delta[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, pos


def apply_delta(base: bytes, delta: bytes) -> bytes:
    """Apply *delta* to *base* and return the reconstructed object payload.

    Raises :class:`CorruptObjectError` when the delta is malformed, does not
    match the base size, copies outside the base or yields the wrong size.
    """
    base_size, pos = _read_size(delta, 0)
    result_size, pos = _read_size(delta, pos)
    if base_size != len(base):
        raise CorruptObjectError("delta base size mismatch")
    out = bytearray()
    n = len(delta)
    while pos < n:
        op = delta[pos]
        pos += 1
        if op & 0x80:
            offset = 0
            size = 0
            for i in range(4):
                if op & (1 << i):
                    if pos >= n:
                        raise CorruptObjectError("truncated delta copy")
                    offset |= delta[pos] << (8 * i)
                    pos += 1
            for i in range(3):
                if op & (0x10 << i):
                    if pos >= n:
                        raise CorruptObjectError("truncated delta copy")
                    size |= delta[pos] << (8 * i)
                    pos += 1
            if size == 0:
                size = 0x10000
            if offset + size > len(base):
                raise CorruptObjectError("delta copy outside base")
            out += base[offset:offset + size]
        elif op:
            if pos + op > n:
                raise CorruptObjectError("truncated delta insert")
            out += delta[pos:pos + op]
            pos += op
        else:
            raise CorruptObjectError("invalid delta opcode 0")
    if len(out) != result_size:
        raise CorruptObjectError("delta result size mismatch")
    return bytes(out)
