"""Content-Transfer-Encoding decoders (quoted-printable and base64)."""

from __future__ import annotations

import re

_QP_ESCAPE = re.compile(rb"=(?:(\n)|([0-9A-Fa-f]{2})|\Z)")
_HEX_BYTES = {
    (a + b).encode(): bytes([int(a + b, 16)])
    for a in "0123456789ABCDEFabcdef"
    for b in "0123456789ABCDEFabcdef"
}


def _qp_replace(m: re.Match[bytes]) -> bytes:
    hexpair = m.group(2)
    return _HEX_BYTES[hexpair] if hexpair is not None else b""


def decode_quoted_printable(data: bytes) -> bytes:
    """Decode quoted-printable *data* (lines already LF-terminated).

    ``=LF`` is a soft break, ``=XX`` is a byte, a final ``=`` vanishes, and any
    other ``=`` is kept literally.  Trailing blanks are never stripped.
    """
    if b"=" not in data:
        return data
    return _QP_ESCAPE.sub(_qp_replace, data)


_B64_ALPHABET = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
#: Maps each alphabet character to its 6-bit value (other entries unused).
_B64_VALUES = bytearray(256)
for _i, _c in enumerate(_B64_ALPHABET):
    _B64_VALUES[_c] = _i
_B64_VALUES = bytes(_B64_VALUES)
#: Every byte that is not in the alphabet; ``=`` is discarded like the rest.
_B64_JUNK = bytes(b for b in range(256) if b not in _B64_ALPHABET)


def decode_base64(data: bytes) -> bytes:
    """Decode base64 *data*, ignoring every byte outside the alphabet.

    Padding is optional: a trailing partial group of two or three characters
    yields one or two bytes and a lone final character is dropped.
    """
    clean = data.translate(_B64_VALUES, _B64_JUNK)
    n = len(clean)
    full = n - n % 4
    a, b, c, d = (clean[k:full:4] for k in range(4))
    out = bytearray(full // 4 * 3)
    out[0::3] = bytes((x << 2) | (y >> 4) for x, y in zip(a, b))
    out[1::3] = bytes(((y & 15) << 4) | (z >> 2) for y, z in zip(b, c))
    out[2::3] = bytes(((z & 3) << 6) | w for z, w in zip(c, d))
    rest = n - full
    if rest >= 2:
        x, y = clean[full], clean[full + 1]
        out.append((x << 2) | (y >> 4))
        if rest == 3:
            z = clean[full + 2]
            out.append(((y & 15) << 4) | (z >> 2))
    return bytes(out)


def decode_body(data: bytes, encoding: str) -> bytes:
    """Decode a part body according to its (normalised) transfer *encoding*.

    Unknown encodings, and ``7bit``/``8bit``/``binary``, leave the bytes as is.
    """
    if encoding == "quoted-printable":
        return decode_quoted_printable(data)
    if encoding == "base64":
        return decode_base64(data)
    return data
