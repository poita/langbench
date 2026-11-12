"""Mode selection and bit-stream construction for a single data segment."""

from __future__ import annotations

import enum
import re

from .tables import MAX_VERSION, MIN_VERSION

ALPHANUMERIC_CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
_ALNUM_VALUE = {ord(c): i for i, c in enumerate(ALPHANUMERIC_CHARSET)}

_NUMERIC_RE = re.compile(rb"[0-9]+")
_ALNUM_RE = re.compile(rb"[0-9A-Z $%*+\-./:]+")


class Mode(enum.Enum):
    """Encoding mode: mode indicator bits and character-count widths."""

    NUMERIC = (0b0001, (10, 12, 14))
    ALPHANUMERIC = (0b0010, (9, 11, 13))
    BYTE = (0b0100, (8, 16, 16))

    def __init__(self, indicator: int, widths: tuple[int, int, int]) -> None:
        self.indicator = indicator
        self._widths = widths

    def count_bits(self, version: int) -> int:
        """Width of the character count indicator at ``version``."""
        return self._widths[(version + 7) // 17]


def select_mode(data: bytes) -> Mode:
    """Numeric if all digits, else alphanumeric if possible, else byte."""
    if _NUMERIC_RE.fullmatch(data):
        return Mode.NUMERIC
    if _ALNUM_RE.fullmatch(data):
        return Mode.ALPHANUMERIC
    return Mode.BYTE


def data_bit_length(mode: Mode, count: int) -> int:
    """Number of payload bits for ``count`` characters (excluding header)."""
    if mode is Mode.NUMERIC:
        return 10 * (count // 3) + (0, 4, 7)[count % 3]
    if mode is Mode.ALPHANUMERIC:
        return 11 * (count // 2) + 6 * (count % 2)
    return 8 * count


def segment_bit_length(mode: Mode, count: int, version: int) -> int:
    """Total bits of mode indicator + count indicator + payload."""
    return 4 + mode.count_bits(version) + data_bit_length(mode, count)


def encode_segment(data: bytes, mode: Mode, version: int) -> tuple[int, int]:
    """Return ``(value, nbits)``: the segment as an MSB-first integer."""
    count = len(data)
    acc = mode.indicator
    nbits = 4
    width = mode.count_bits(version)
    if count >= 1 << width:
        raise ValueError("segment too long for character count field")
    acc = (acc << width) | count
    nbits += width

    if mode is Mode.NUMERIC:
        for i in range(0, count - 2, 3):
            acc = (acc << 10) | int(data[i : i + 3])
            nbits += 10
        rest = count % 3
        if rest:
            acc = (acc << (3 * rest + 1)) | int(data[count - rest :])
            nbits += 3 * rest + 1
    elif mode is Mode.ALPHANUMERIC:
        vals = [_ALNUM_VALUE[b] for b in data]
        for i in range(0, count - 1, 2):
            acc = (acc << 11) | (45 * vals[i] + vals[i + 1])
            nbits += 11
        if count % 2:
            acc = (acc << 6) | vals[-1]
            nbits += 6
    else:
        acc = (acc << (8 * count)) | int.from_bytes(data, "big")
        nbits += 8 * count
    return acc, nbits


def choose_version(mode: Mode, count: int, capacity) -> int | None:
    """Smallest version whose capacity (in data codewords, via the callable
    ``capacity(version)``) holds the segment, or ``None`` if none does."""
    for v in range(MIN_VERSION, MAX_VERSION + 1):
        if segment_bit_length(mode, count, v) <= 8 * capacity(v):
            return v
    return None


def to_codewords(value: int, nbits: int, capacity: int) -> bytes:
    """Terminate, byte-align and pad a bit stream to ``capacity`` codewords."""
    total = 8 * capacity
    if nbits > total:
        raise ValueError("bit stream exceeds capacity")
    term = min(4, total - nbits)
    value <<= term
    nbits += term
    align = -nbits % 8
    value <<= align
    nbits += align
    out = value.to_bytes(nbits // 8, "big")
    pad = capacity - len(out)
    if pad:
        out += (b"\xec\x11" * ((pad + 1) // 2))[:pad]
    return out
