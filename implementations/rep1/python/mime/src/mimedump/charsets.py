"""Character-set decoding.

Only a handful of charsets are understood (ASCII, UTF-8, Latin-1 and
Windows-1252); every other name falls back to Windows-1252.  Decoding never
fails: undecodable input becomes U+FFFD.
"""

from __future__ import annotations

from .textutil import ascii_lower, strip_blanks

_ASCII_NAMES = frozenset({"us-ascii", "ascii", "iso-ir-6", "ansi_x3.4-1968", "iso646-us"})
_UTF8_NAMES = frozenset({"utf-8", "utf8", "unicode-1-1-utf-8"})
_LATIN1_NAMES = frozenset(
    {"iso-8859-1", "iso8859-1", "latin-1", "latin1", "l1", "8859-1", "iso_8859-1"}
)

#: Code points for the bytes 0x80-0x9F in Windows-1252 (all 32 are defined).
_CP1252_HIGH = (
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
)
_CP1252_FIXUPS = {0x80 + i: cp for i, cp in enumerate(_CP1252_HIGH) if cp != 0x80 + i}


def normalize_charset(name: str) -> str:
    """Strip blanks and lower-case the ASCII letters of a charset name."""
    return ascii_lower(strip_blanks(name))


# (first byte) -> (sequence length, lowest and highest allowed second byte)
def _utf8_lead(b0: int) -> tuple[int, int, int] | None:
    if 0xC2 <= b0 <= 0xDF:
        return 2, 0x80, 0xBF
    if b0 == 0xE0:
        return 3, 0xA0, 0xBF
    if 0xE1 <= b0 <= 0xEC or 0xEE <= b0 <= 0xEF:
        return 3, 0x80, 0xBF
    if b0 == 0xED:
        return 3, 0x80, 0x9F
    if b0 == 0xF0:
        return 4, 0x90, 0xBF
    if 0xF1 <= b0 <= 0xF3:
        return 4, 0x80, 0xBF
    if b0 == 0xF4:
        return 4, 0x80, 0x8F
    return None


def decode_utf8_lenient(data: bytes) -> str:
    """Decode UTF-8, replacing invalid input by the maximal-subpart rule.

    This is the byte-by-byte reference implementation of the rule; see
    :func:`decode_utf8` for the entry point that is fast on valid input.
    """
    out: list[str] = []
    n = len(data)
    i = 0
    while i < n:
        b0 = data[i]
        if b0 < 0x80:
            out.append(chr(b0))
            i += 1
            continue
        lead = _utf8_lead(b0)
        if lead is None:
            out.append("\ufffd")
            i += 1
            continue
        length, lo, hi = lead
        cp = b0 & (0x1F if length == 2 else 0x0F if length == 3 else 0x07)
        j = i + 1
        ok = True
        for k in range(1, length):
            if j >= n:
                ok = False
                break
            b = data[j]
            if not (lo <= b <= hi if k == 1 else 0x80 <= b <= 0xBF):
                ok = False
                break
            cp = (cp << 6) | (b & 0x3F)
            j += 1
        if ok:
            out.append(chr(cp))
        else:
            out.append("\ufffd")
        i = j
    return "".join(out)


def decode_utf8(data: bytes) -> str:
    """Decode UTF-8 with maximal-subpart replacement of invalid sequences."""
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return decode_utf8_lenient(data)


def decode(data: bytes, charset: str) -> str:
    """Decode *data* using the named *charset* (see module docstring)."""
    name = normalize_charset(charset)
    if name in _UTF8_NAMES:
        return decode_utf8(data)
    if name in _ASCII_NAMES:
        return data.decode("ascii", errors="replace")
    text = data.decode("latin-1")
    if name in _LATIN1_NAMES:
        return text
    return text.translate(_CP1252_FIXUPS)
