"""DEFLATE (RFC 1951) and zlib (RFC 1950) decompression, from scratch.

The public entry points are :func:`zlib_decompress`, which also reports where
the compressed stream ended (needed to walk concatenated streams in a
packfile), and :func:`inflate`, which decodes a raw DEFLATE stream.
"""

from __future__ import annotations

from .errors import CorruptObjectError

_LEN_BASE = (3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
             67, 83, 99, 115, 131, 163, 195, 227, 258)
_LEN_EXTRA = (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
              4, 4, 4, 4, 5, 5, 5, 5, 0)
_DIST_BASE = (1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513,
              769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577)
_DIST_EXTRA = (0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
               9, 9, 10, 10, 11, 11, 12, 12, 13, 13)
_CLEN_ORDER = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15)

# A lookup table is (list, mask).  Each entry is ``(symbol << 4) | code_length``
# indexed by the next ``maxbits`` input bits (LSB first); 0 marks an unused code.
_Table = tuple[list[int], int]


def _build_table(lengths: list[int]) -> _Table:
    """Build a decoding table for the canonical Huffman code *lengths*."""
    maxbits = max(lengths) if lengths else 0
    if maxbits == 0:
        return [0, 0], 1
    count = [0] * (maxbits + 1)
    for n in lengths:
        count[n] += 1
    count[0] = 0
    left = 1
    for n in range(1, maxbits + 1):
        left = (left << 1) - count[n]
        if left < 0:
            raise CorruptObjectError("oversubscribed Huffman code")
    next_code = [0] * (maxbits + 2)
    code = 0
    for n in range(1, maxbits + 1):
        code = (code + count[n - 1]) << 1
        next_code[n] = code
    size = 1 << maxbits
    table = [0] * size
    for sym, n in enumerate(lengths):
        if n == 0:
            continue
        code = next_code[n]
        next_code[n] = code + 1
        rev = int(format(code, f"0{n}b")[::-1], 2)
        step = 1 << n
        table[rev::step] = [(sym << 4) | n] * len(range(rev, size, step))
    return table, size - 1


_FIXED: tuple[_Table, _Table] | None = None


def _fixed_tables() -> tuple[_Table, _Table]:
    global _FIXED
    if _FIXED is None:
        lit = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
        _FIXED = (_build_table(lit), _build_table([5] * 30))
    return _FIXED


def inflate(data: bytes, pos: int = 0) -> tuple[bytes, int]:
    """Decode the raw DEFLATE stream starting at ``data[pos]``.

    Returns ``(output, end)`` where *end* is the offset of the first byte after
    the stream.  Raises :class:`CorruptObjectError` if the stream is invalid or
    truncated.
    """
    n = len(data)
    out = bytearray()
    bitbuf = 0
    bitcnt = 0
    limit = n + 12  # virtual zero padding allowed past the end, then give up
    last = False
    from_bytes = int.from_bytes
    len_base, len_extra = _LEN_BASE, _LEN_EXTRA
    dist_base, dist_extra = _DIST_BASE, _DIST_EXTRA

    while not last:
        if bitcnt < 48:
            bitbuf |= from_bytes(data[pos:pos + 6], "little") << bitcnt
            pos += 6
            bitcnt += 48
            if pos > limit:
                raise CorruptObjectError("truncated DEFLATE stream")
        last = bool(bitbuf & 1)
        btype = (bitbuf >> 1) & 3
        bitbuf >>= 3
        bitcnt -= 3

        if btype == 0:
            # Stored block: realign to a byte boundary and copy LEN bytes.
            pos -= bitcnt >> 3
            bitbuf = 0
            bitcnt = 0
            if pos + 4 > n:
                raise CorruptObjectError("truncated stored block")
            ln = data[pos] | (data[pos + 1] << 8)
            nln = data[pos + 2] | (data[pos + 3] << 8)
            if ln ^ nln != 0xFFFF:
                raise CorruptObjectError("stored block length mismatch")
            pos += 4
            if pos + ln > n:
                raise CorruptObjectError("truncated stored block")
            out += data[pos:pos + ln]
            pos += ln
            continue
        if btype == 3:
            raise CorruptObjectError("invalid DEFLATE block type")

        if btype == 1:
            (lit, lmask), (dst, dmask) = _fixed_tables()
        else:
            if bitcnt < 14:
                bitbuf |= from_bytes(data[pos:pos + 6], "little") << bitcnt
                pos += 6
                bitcnt += 48
            hlit = (bitbuf & 31) + 257
            hdist = ((bitbuf >> 5) & 31) + 1
            hclen = ((bitbuf >> 10) & 15) + 4
            bitbuf >>= 14
            bitcnt -= 14
            if hlit > 286 or hdist > 30:
                raise CorruptObjectError("too many length or distance codes")
            clens = [0] * 19
            for i in range(hclen):
                if bitcnt < 3:
                    bitbuf |= from_bytes(data[pos:pos + 6], "little") << bitcnt
                    pos += 6
                    bitcnt += 48
                clens[_CLEN_ORDER[i]] = bitbuf & 7
                bitbuf >>= 3
                bitcnt -= 3
            ctable, cmask = _build_table(clens)
            lengths: list[int] = []
            total = hlit + hdist
            while len(lengths) < total:
                if bitcnt < 32:
                    bitbuf |= from_bytes(data[pos:pos + 6], "little") << bitcnt
                    pos += 6
                    bitcnt += 48
                    if pos > limit:
                        raise CorruptObjectError("truncated DEFLATE stream")
                e = ctable[bitbuf & cmask]
                ln = e & 15
                if ln == 0:
                    raise CorruptObjectError("invalid code length code")
                bitbuf >>= ln
                bitcnt -= ln
                sym = e >> 4
                if sym < 16:
                    lengths.append(sym)
                    continue
                if sym == 16:
                    if not lengths:
                        raise CorruptObjectError("repeat with no previous length")
                    rep = 3 + (bitbuf & 3)
                    bitbuf >>= 2
                    bitcnt -= 2
                    lengths.extend([lengths[-1]] * rep)
                elif sym == 17:
                    rep = 3 + (bitbuf & 7)
                    bitbuf >>= 3
                    bitcnt -= 3
                    lengths.extend([0] * rep)
                else:
                    rep = 11 + (bitbuf & 127)
                    bitbuf >>= 7
                    bitcnt -= 7
                    lengths.extend([0] * rep)
            if len(lengths) > total:
                raise CorruptObjectError("code lengths overflow")
            if lengths[256] == 0:
                raise CorruptObjectError("missing end-of-block code")
            lit, lmask = _build_table(lengths[:hlit])
            dst, dmask = _build_table(lengths[hlit:])

        # Decode symbols.  At least 48 bits are buffered at the top of each
        # iteration: enough for a length code, its extra bits, a distance code
        # and its extra bits.
        while True:
            if bitcnt < 48:
                bitbuf |= from_bytes(data[pos:pos + 6], "little") << bitcnt
                pos += 6
                bitcnt += 48
                if pos > limit:
                    raise CorruptObjectError("truncated DEFLATE stream")
            e = lit[bitbuf & lmask]
            ln = e & 15
            if ln == 0:
                raise CorruptObjectError("invalid literal/length code")
            bitbuf >>= ln
            bitcnt -= ln
            sym = e >> 4
            if sym < 256:
                out.append(sym)
                continue
            if sym == 256:
                break
            sym -= 257
            if sym >= 29:
                raise CorruptObjectError("invalid length symbol")
            eb = len_extra[sym]
            length = len_base[sym] + (bitbuf & ((1 << eb) - 1))
            bitbuf >>= eb
            bitcnt -= eb
            e = dst[bitbuf & dmask]
            ln = e & 15
            if ln == 0:
                raise CorruptObjectError("invalid distance code")
            bitbuf >>= ln
            bitcnt -= ln
            sym = e >> 4
            if sym >= 30:
                raise CorruptObjectError("invalid distance symbol")
            eb = dist_extra[sym]
            dist = dist_base[sym] + (bitbuf & ((1 << eb) - 1))
            bitbuf >>= eb
            bitcnt -= eb
            size = len(out)
            if dist > size:
                raise CorruptObjectError("distance too far back")
            start = size - dist
            if dist >= length:
                out += out[start:start + length]
            else:
                chunk = out[start:]
                out += (chunk * (length // dist + 1))[:length]

    end = pos - (bitcnt >> 3)
    if end > n:
        raise CorruptObjectError("truncated DEFLATE stream")
    return bytes(out), end


def adler32(data: bytes) -> int:
    """Return the Adler-32 checksum of *data*."""
    from itertools import accumulate

    a = (1 + sum(data)) % 65521
    b = (len(data) + sum(accumulate(data))) % 65521
    return (b << 16) | a


def zlib_decompress(data: bytes, pos: int = 0, verify: bool = True) -> tuple[bytes, int]:
    """Decode the zlib stream (RFC 1950) starting at ``data[pos]``.

    Returns ``(output, end)`` with *end* the offset just past the Adler-32
    trailer.  Raises :class:`CorruptObjectError` for a bad header, a bad
    DEFLATE stream, a truncated stream or (when *verify* is true) a checksum
    mismatch.
    """
    if pos + 2 > len(data):
        raise CorruptObjectError("truncated zlib header")
    cmf, flg = data[pos], data[pos + 1]
    if cmf & 0x0F != 8 or (cmf * 256 + flg) % 31 != 0 or flg & 0x20:
        raise CorruptObjectError("invalid zlib header")
    out, end = inflate(data, pos + 2)
    if end + 4 > len(data):
        raise CorruptObjectError("truncated zlib trailer")
    if verify and int.from_bytes(data[end:end + 4], "big") != adler32(out):
        raise CorruptObjectError("zlib checksum mismatch")
    return out, end + 4
