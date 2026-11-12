"""The DEFLATE block decoder."""

from __future__ import annotations

from .bitreader import BitReader
from .errors import InflateError, TrailingDataError, TruncatedStreamError
from .huffman import HuffmanTable, build_table, fixed_tables
from .tables import (
    CODE_LENGTH_ORDER,
    DIST_BASE,
    DIST_EXTRA,
    END_OF_BLOCK,
    LENGTH_BASE,
    LENGTH_EXTRA,
    MAX_DIST_SYMBOLS,
    MAX_LITLEN_SYMBOLS,
)

_LIT_ROOT_BITS = 10
_DIST_ROOT_BITS = 8
_CODELEN_ROOT_BITS = 7

_LENGTH_MASK = tuple((1 << n) - 1 for n in LENGTH_EXTRA)
_DIST_MASK = tuple((1 << n) - 1 for n in DIST_EXTRA)


def inflate(data: bytes | bytearray | memoryview) -> bytes:
    """Decompress the raw DEFLATE stream ``data`` and return the result.

    Raises :class:`~inflate.errors.InflateError` (or a subclass) if the stream
    is malformed, truncated, or followed by trailing whole bytes.
    """
    reader = BitReader(bytes(data))
    out = bytearray()
    final = False
    while not final:
        header = reader.read(3)
        final = bool(header & 1)
        block_type = header >> 1
        if block_type == 0:
            _stored_block(reader, out)
        elif block_type == 1:
            lit, dist = fixed_tables()
            _huffman_block(reader, out, lit, dist)
        elif block_type == 2:
            lit, dist = _read_dynamic_tables(reader)
            _huffman_block(reader, out, lit, dist)
        else:
            raise InflateError("invalid block type 3")
    if reader.remaining_bytes():
        raise TrailingDataError("trailing data after final block")
    return bytes(out)


def _stored_block(reader: BitReader, out: bytearray) -> None:
    reader.align_to_byte()
    length = reader.read(16)
    nlength = reader.read(16)
    if length ^ nlength != 0xFFFF:
        raise InflateError("stored block LEN/NLEN mismatch")
    out += reader.read_aligned_bytes(length)


def _read_dynamic_tables(reader: BitReader) -> tuple[HuffmanTable, HuffmanTable]:
    hlit = reader.read(5)
    hdist = reader.read(5)
    hclen = reader.read(4)
    if hlit > MAX_LITLEN_SYMBOLS - 257 or hdist > MAX_DIST_SYMBOLS - 1:
        raise InflateError("too many length or distance codes")
    n_lit = hlit + 257
    total = n_lit + hdist + 1

    cl_lengths = [0] * 19
    for i in range(hclen + 4):
        cl_lengths[CODE_LENGTH_ORDER[i]] = reader.read(3)
    cl_table = build_table(cl_lengths, _CODELEN_ROOT_BITS)
    if not cl_table.complete:
        raise InflateError("code-length code is not complete")

    lengths: list[int] = []
    while len(lengths) < total:
        sym = reader.decode(cl_table)
        if sym < 16:
            lengths.append(sym)
            continue
        if sym == 16:
            if not lengths:
                raise InflateError("repeat with no previous length")
            value = lengths[-1]
            repeat = 3 + reader.read(2)
        elif sym == 17:
            value = 0
            repeat = 3 + reader.read(3)
        else:
            value = 0
            repeat = 11 + reader.read(7)
        if len(lengths) + repeat > total:
            raise InflateError("code length repeat overflows")
        lengths.extend([value] * repeat)

    lit_lengths = lengths[:n_lit]
    dist_lengths = lengths[n_lit:]
    if not lit_lengths[END_OF_BLOCK]:
        raise InflateError("no end-of-block code")
    lit = build_table(lit_lengths, _LIT_ROOT_BITS)
    if not (lit.complete or lit.single_bit):
        raise InflateError("literal/length code is not complete")
    dist = build_table(dist_lengths, _DIST_ROOT_BITS)
    if not (dist.complete or dist.single_bit or dist.used == 0):
        raise InflateError("distance code is not complete")
    return lit, dist


def _huffman_block(
    reader: BitReader,
    out: bytearray,
    lit: HuffmanTable,
    dist: HuffmanTable,
) -> None:
    """Decode symbols of one compressed block until end-of-block.

    This is the hot loop: reader state lives in local variables, and every
    symbol needs one or two table lookups.  At least 48 bits (the longest
    possible length code + extra + distance code + extra) are buffered before
    each symbol.  Missing input is treated as zero bits and detected when
    the bits would be consumed.
    """
    data = reader.data
    n = len(data)
    nbits = n * 8
    pos = reader.pos
    bitbuf = reader.bitbuf
    bitcnt = reader.bitcnt

    lit_entries = lit.entries
    lbits = lit.root_bits
    lmask = (1 << lbits) - 1
    dist_entries = dist.entries
    dbits = dist.root_bits
    dmask = (1 << dbits) - 1
    length_base, length_extra, length_mask = LENGTH_BASE, LENGTH_EXTRA, _LENGTH_MASK
    dist_base, dist_extra, dist_mask = DIST_BASE, DIST_EXTRA, _DIST_MASK
    from_bytes = int.from_bytes
    append = out.append

    while True:
        if bitcnt < 48:
            bitbuf |= from_bytes(data[pos : pos + 6], "little") << bitcnt
            pos += 6
            bitcnt += 48
            if pos > n and pos * 8 - bitcnt > nbits:
                raise TruncatedStreamError("unexpected end of stream")

        entry = lit_entries[bitbuf & lmask]
        if entry <= 0:
            if entry == 0:
                raise InflateError("invalid literal/length code")
            entry = ~entry
            entry = lit_entries[(entry >> 4) + ((bitbuf >> lbits) & ((1 << (entry & 15)) - 1))]
            if entry == 0:
                raise InflateError("invalid literal/length code")
        code_len = entry & 15
        bitbuf >>= code_len
        bitcnt -= code_len
        sym = entry >> 4

        if sym < 256:
            append(sym)
            continue
        if sym == END_OF_BLOCK:
            break
        if sym > 285:
            raise InflateError("invalid length symbol")
        sym -= 257
        extra = length_extra[sym]
        length = length_base[sym] + (bitbuf & length_mask[sym])
        bitbuf >>= extra
        bitcnt -= extra

        entry = dist_entries[bitbuf & dmask]
        if entry <= 0:
            if entry == 0:
                raise InflateError("invalid distance code")
            entry = ~entry
            entry = dist_entries[(entry >> 4) + ((bitbuf >> dbits) & ((1 << (entry & 15)) - 1))]
            if entry == 0:
                raise InflateError("invalid distance code")
        code_len = entry & 15
        bitbuf >>= code_len
        bitcnt -= code_len
        sym = entry >> 4
        if sym > 29:
            raise InflateError("invalid distance symbol")
        extra = dist_extra[sym]
        distance = dist_base[sym] + (bitbuf & dist_mask[sym])
        bitbuf >>= extra
        bitcnt -= extra

        start = len(out) - distance
        if start < 0:
            raise InflateError("distance too far back")
        if distance >= length:
            out += out[start : start + length]
        else:
            quotient, remainder = divmod(length, distance)
            chunk = out[start:]
            out += chunk * quotient + chunk[:remainder]

    # Normalise the state: the loop may have loaded zero padding past the end.
    if pos * 8 - bitcnt > nbits:
        raise TruncatedStreamError("unexpected end of stream")
    if pos > n:
        bitcnt -= (pos - n) * 8
        bitbuf &= (1 << bitcnt) - 1
        pos = n
    reader.pos = pos
    reader.bitbuf = bitbuf
    reader.bitcnt = bitcnt
