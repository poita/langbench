"""Base64 encoding and strict decoding, implemented from scratch.

Two alphabets are supported: the standard one (``+/``, padded) and the
URL-safe one (``-_``, unpadded).  :func:`b64decode` accepts either alphabet
(but not a mixture) and enforces canonical padding.
"""

from __future__ import annotations

__all__ = ["Base64Error", "b64encode", "b64urlencode", "b64decode"]

_STANDARD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
_URLSAFE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

_STD_BYTES = _STANDARD.encode("ascii")
_URL_BYTES = _URLSAFE.encode("ascii")

# Decoding table: byte value -> 6-bit value, for both alphabets.
_DECODE: dict[int, int] = {c: i for i, c in enumerate(_STD_BYTES)}
_DECODE.update({c: i for i, c in enumerate(_URL_BYTES)})

_PLUS_SLASH = b"+/"
_DASH_UNDERSCORE = b"-_"
_PAD = ord("=")


class Base64Error(ValueError):
    """Raised when a string is not valid Base64 under the strict rules."""


def _encode(data: bytes, alphabet: bytes, pad: bool) -> str:
    out = bytearray()
    n = len(data)
    full = n - n % 3
    for i in range(0, full, 3):
        v = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2]
        out.append(alphabet[v >> 18])
        out.append(alphabet[(v >> 12) & 63])
        out.append(alphabet[(v >> 6) & 63])
        out.append(alphabet[v & 63])
    rest = n - full
    if rest == 1:
        v = data[full] << 16
        out.append(alphabet[v >> 18])
        out.append(alphabet[(v >> 12) & 63])
        if pad:
            out += b"=="
    elif rest == 2:
        v = (data[full] << 16) | (data[full + 1] << 8)
        out.append(alphabet[v >> 18])
        out.append(alphabet[(v >> 12) & 63])
        out.append(alphabet[(v >> 6) & 63])
        if pad:
            out += b"="
    return out.decode("ascii")


def b64encode(data: bytes) -> str:
    """Encode *data* as padded standard Base64."""
    return _encode(bytes(data), _STD_BYTES, True)


def b64urlencode(data: bytes) -> str:
    """Encode *data* as unpadded URL-safe Base64."""
    return _encode(bytes(data), _URL_BYTES, False)


def b64decode(text: str | bytes) -> bytes:
    """Decode *text* (either alphabet, optional canonical padding).

    Raises :class:`Base64Error` if the text is invalid: padding in the wrong
    place or amount, a character outside both alphabets, both alphabets
    mixed, or a length of ``1 (mod 4)``.  Left-over low bits in the final
    character are discarded without being checked.
    """
    if isinstance(text, str):
        try:
            text = text.encode("ascii")
        except UnicodeEncodeError:
            raise Base64Error("non-ASCII character") from None
    body = text.rstrip(b"=")
    pad = len(text) - len(body)
    if b"=" in body:
        raise Base64Error("'=' in the middle of the string")
    if pad > 2:
        raise Base64Error("too much padding")
    decode = _DECODE
    for c in body:
        if c not in decode:
            raise Base64Error(f"invalid character {chr(c)!r}")
    if any(c in body for c in _PLUS_SLASH) and any(c in body for c in _DASH_UNDERSCORE):
        raise Base64Error("mixed alphabets")
    n = len(body)
    rem = n % 4
    if rem == 1:
        raise Base64Error("impossible length")
    if pad:
        expected = {0: 0, 2: 2, 3: 1}[rem]
        if pad != expected:
            raise Base64Error("incorrect padding")

    out = bytearray()
    acc = 0
    bits = 0
    for c in body:
        acc = (acc << 6) | decode[c]
        bits += 6
        if bits >= 8:
            bits -= 8
            out.append((acc >> bits) & 0xFF)
            acc &= (1 << bits) - 1
    return bytes(out)
