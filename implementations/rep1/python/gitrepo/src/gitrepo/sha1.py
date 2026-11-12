"""SHA-1 (FIPS 180-4) implemented from scratch.

The module offers a streaming :class:`Sha1` object and the one-shot helpers
:func:`sha1_digest` and :func:`sha1_hex`.
"""

from __future__ import annotations

import struct

_MASK = 0xFFFFFFFF
_BLOCK = struct.Struct(">16I")


def _compress(state: tuple[int, int, int, int, int], blocks: bytes) -> tuple[int, int, int, int, int]:
    """Run the compression function over *blocks* (a multiple of 64 bytes)."""
    h0, h1, h2, h3, h4 = state
    for words in _BLOCK.iter_unpack(blocks):
        w = list(words)
        append = w.append
        for i in range(16, 80):
            x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
            append(((x << 1) | (x >> 31)) & _MASK)
        a, b, c, d, e = h0, h1, h2, h3, h4
        for i in range(0, 20):
            t = ((((a << 5) | (a >> 27)) & _MASK) + ((b & c) | (~b & d)) + e + 0x5A827999 + w[i]) & _MASK
            e = d
            d = c
            c = ((b << 30) | (b >> 2)) & _MASK
            b = a
            a = t
        for i in range(20, 40):
            t = ((((a << 5) | (a >> 27)) & _MASK) + (b ^ c ^ d) + e + 0x6ED9EBA1 + w[i]) & _MASK
            e = d
            d = c
            c = ((b << 30) | (b >> 2)) & _MASK
            b = a
            a = t
        for i in range(40, 60):
            t = ((((a << 5) | (a >> 27)) & _MASK) + ((b & c) | (b & d) | (c & d)) + e + 0x8F1BBCDC + w[i]) & _MASK
            e = d
            d = c
            c = ((b << 30) | (b >> 2)) & _MASK
            b = a
            a = t
        for i in range(60, 80):
            t = ((((a << 5) | (a >> 27)) & _MASK) + (b ^ c ^ d) + e + 0xCA62C1D6 + w[i]) & _MASK
            e = d
            d = c
            c = ((b << 30) | (b >> 2)) & _MASK
            b = a
            a = t
        h0 = (h0 + a) & _MASK
        h1 = (h1 + b) & _MASK
        h2 = (h2 + c) & _MASK
        h3 = (h3 + d) & _MASK
        h4 = (h4 + e) & _MASK
    return h0, h1, h2, h3, h4


class Sha1:
    """Incremental SHA-1 hasher with a ``hashlib``-like interface."""

    digest_size = 20
    block_size = 64

    def __init__(self, data: bytes = b"") -> None:
        self._state = (0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0)
        self._pending = b""
        self._length = 0
        if data:
            self.update(data)

    def update(self, data: bytes) -> None:
        """Feed *data* into the hash."""
        data = bytes(data)
        self._length += len(data)
        buf = self._pending + data if self._pending else data
        whole = len(buf) - (len(buf) % 64)
        if whole:
            self._state = _compress(self._state, buf[:whole])
        self._pending = buf[whole:]

    def digest(self) -> bytes:
        """Return the 20-byte digest of the data fed so far."""
        tail = self._pending + b"\x80"
        tail += b"\x00" * ((56 - len(tail)) % 64)
        tail += struct.pack(">Q", (self._length * 8) & 0xFFFFFFFFFFFFFFFF)
        return struct.pack(">5I", *_compress(self._state, tail))

    def hexdigest(self) -> str:
        """Return the digest as 40 lowercase hexadecimal digits."""
        return self.digest().hex()


def sha1_digest(data: bytes) -> bytes:
    """Return the SHA-1 digest of *data* as 20 raw bytes."""
    return Sha1(data).digest()


def sha1_hex(data: bytes) -> str:
    """Return the SHA-1 digest of *data* as 40 lowercase hex digits."""
    return Sha1(data).hexdigest()
