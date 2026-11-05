#!/usr/bin/env python3
"""Reference DEFLATE (RFC 1951) decoder.

Reads one line of lowercase hex (a raw DEFLATE stream) from stdin and writes
the decompressed bytes as lowercase hex, or the single word "error" when the
stream is malformed according to SPEC.md. Pure Python, no zlib.
"""
import sys

# Base values and extra-bit counts for length symbols 257..285.
LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51,
         59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
LEXT = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
        5, 5, 5, 5, 0]
# Base values and extra-bit counts for distance symbols 0..29.
DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
         513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385,
         24577]
DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10,
        10, 11, 11, 12, 12, 13, 13]
# Order in which code-length-code lengths appear in a dynamic block header.
CLEN_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

MAXBITS = 15


class InflateError(Exception):
    pass


def build_table(lengths, allow_incomplete):
    """Builds a direct lookup table for a canonical Huffman code.

    Returns (table, maxlen). table[i] for the next maxlen input bits (taken
    LSB-first, i.e. the code bit-reversed) holds (codelen << 16) | symbol, or
    -1 for a bit pattern that is not a code. An over-subscribed set is always
    rejected. An incomplete set is rejected unless allow_incomplete is set and
    the set is empty or a single code of length 1.
    """
    count = [0] * (MAXBITS + 1)
    for l in lengths:
        count[l] += 1
    count[0] = 0
    ncodes = sum(count)
    maxlen = 0
    for l in range(MAXBITS, 0, -1):
        if count[l]:
            maxlen = l
            break
    left = 1
    for l in range(1, MAXBITS + 1):
        left = (left << 1) - count[l]
        if left < 0:
            raise InflateError("over-subscribed code")
    if left > 0:
        # Incomplete set: only an empty set or a lone 1-bit code may be accepted.
        if not allow_incomplete or ncodes > 1 or (ncodes == 1 and maxlen != 1):
            raise InflateError("incomplete code")
    if maxlen == 0:
        return [], 0
    # Canonical code assignment (RFC 1951 3.2.2).
    next_code = [0] * (MAXBITS + 2)
    code = 0
    for l in range(1, MAXBITS + 1):
        code = (code + count[l - 1]) << 1
        next_code[l] = code
    size = 1 << maxlen
    table = [-1] * size
    for sym, l in enumerate(lengths):
        if l == 0:
            continue
        c = next_code[l]
        next_code[l] += 1
        # Reverse the code so it can be matched against LSB-first input bits.
        r = 0
        for _ in range(l):
            r = (r << 1) | (c & 1)
            c >>= 1
        entry = (l << 16) | sym
        step = 1 << l
        for i in range(r, size, step):
            table[i] = entry
    return table, maxlen


def _fixed_tables():
    lit = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
    dist = [5] * 32
    return build_table(lit, False), build_table(dist, False)


FIXED_LIT, FIXED_DIST = _fixed_tables()


def inflate(data, stats=None):
    """Decompresses a raw DEFLATE stream. Raises InflateError if malformed.

    When stats is a dict it is filled with coverage information (block types,
    largest distance/length seen, code-length codes used, ...).
    """
    n = len(data)
    out = bytearray()
    # Bit reader state: bitbuf holds bitcnt bits, the low bits being the next
    # ones in the stream. Reading past the end of data appends zero bits and
    # counts them in pad; consuming a pad bit is a truncation error.
    pos = 0
    bitbuf = 0
    bitcnt = 0
    pad = 0
    maxdist = 0
    maxlen = 0
    if stats is not None:
        stats.setdefault("blocks", [])
        stats.setdefault("clen_codes", set())
        stats.setdefault("stored_bytes", 0)

    def need(k):
        nonlocal pos, bitbuf, bitcnt, pad
        while bitcnt < k:
            if pos < n:
                bitbuf |= data[pos] << bitcnt
                pos += 1
            else:
                pad += 8
            bitcnt += 8

    def getbits(k):
        nonlocal bitbuf, bitcnt
        if k == 0:
            return 0
        if bitcnt < k:
            need(k)
        if k > bitcnt - pad:
            raise InflateError("truncated")
        v = bitbuf & ((1 << k) - 1)
        bitbuf >>= k
        bitcnt -= k
        return v

    def decode(table, tmax):
        nonlocal bitbuf, bitcnt
        if bitcnt < tmax:
            need(tmax)
        e = table[bitbuf & ((1 << tmax) - 1)]
        if e < 0:
            raise InflateError("invalid code")
        l = e >> 16
        if l > bitcnt - pad:
            raise InflateError("truncated")
        bitbuf >>= l
        bitcnt -= l
        return e & 0xFFFF

    def read_dynamic_tables():
        hlit = getbits(5) + 257
        hdist = getbits(5) + 1
        hclen = getbits(4) + 4
        if hlit > 286 or hdist > 30:
            raise InflateError("too many length or distance symbols")
        clen = [0] * 19
        for i in range(hclen):
            clen[CLEN_ORDER[i]] = getbits(3)
        ctable, cmax = build_table(clen, False)
        if cmax == 0:
            raise InflateError("empty code length code")
        lengths = []
        total = hlit + hdist
        while len(lengths) < total:
            sym = decode(ctable, cmax)
            if sym < 16:
                lengths.append(sym)
                continue
            if stats is not None:
                stats["clen_codes"].add(sym)
            if sym == 16:
                if not lengths:
                    raise InflateError("repeat with no previous length")
                rep = 3 + getbits(2)
                val = lengths[-1]
            elif sym == 17:
                rep = 3 + getbits(3)
                val = 0
            else:
                rep = 11 + getbits(7)
                val = 0
            if len(lengths) + rep > total:
                raise InflateError("repeat overflows code lengths")
            lengths.extend([val] * rep)
        lit = lengths[:hlit]
        dist = lengths[hlit:]
        if lit[256] == 0:
            raise InflateError("missing end-of-block code")
        lt = build_table(lit, True)
        dt = build_table(dist, True)
        if stats is not None:
            stats["max_litlen_bits"] = max(stats.get("max_litlen_bits", 0), lt[1])
            stats["max_dist_bits"] = max(stats.get("max_dist_bits", 0), dt[1])
            stats["hlit_max"] = max(stats.get("hlit_max", 0), hlit)
            stats["hdist_max"] = max(stats.get("hdist_max", 0), hdist)
            if dt[1] == 0:
                stats["empty_dist"] = True
            elif sum(1 for l in dist if l) == 1:
                stats["single_dist"] = True
            if sum(1 for l in lit if l) == 1:
                stats["single_lit"] = True
        return lt, dt

    final = 0
    while not final:
        final = getbits(1)
        btype = getbits(2)
        if btype == 3:
            raise InflateError("invalid block type")
        if stats is not None:
            stats["blocks"].append(btype)
        if btype == 0:
            # Stored block: discard the rest of the current byte, then
            # LEN, NLEN (little-endian 16-bit) and LEN raw bytes follow.
            drop = bitcnt & 7
            bitbuf >>= drop
            bitcnt -= drop
            ln = getbits(16)
            nln = getbits(16)
            if ln != (~nln & 0xFFFF):
                raise InflateError("stored block length mismatch")
            rem = ln
            # Bytes still sitting in the bit buffer come out first.
            while rem and bitcnt - pad >= 8:
                out.append(getbits(8))
                rem -= 1
            if rem:
                if bitcnt - pad != 0:
                    raise InflateError("truncated")
                if pos + rem > n:
                    raise InflateError("truncated")
                out += data[pos:pos + rem]
                pos += rem
            if stats is not None:
                stats["stored_bytes"] += ln
            continue
        if btype == 1:
            (lt, lmax), (dt, dmax) = FIXED_LIT, FIXED_DIST
        else:
            (lt, lmax), (dt, dmax) = read_dynamic_tables()
        lmask = (1 << lmax) - 1
        dmask = (1 << dmax) - 1
        while True:
            # Inline symbol decode: this is the hot path.
            while bitcnt < lmax:
                if pos < n:
                    bitbuf |= data[pos] << bitcnt
                    pos += 1
                else:
                    pad += 8
                bitcnt += 8
            e = lt[bitbuf & lmask]
            if e < 0:
                raise InflateError("invalid literal/length code")
            l = e >> 16
            if l > bitcnt - pad:
                raise InflateError("truncated")
            bitbuf >>= l
            bitcnt -= l
            sym = e & 0xFFFF
            if sym < 256:
                out.append(sym)
                continue
            if sym == 256:
                break
            sym -= 257
            if sym >= 29:
                raise InflateError("invalid literal/length code")
            length = LBASE[sym]
            eb = LEXT[sym]
            if eb:
                length += getbits(eb)
            if dmax == 0:
                raise InflateError("length code with no distance codes")
            while bitcnt < dmax:
                if pos < n:
                    bitbuf |= data[pos] << bitcnt
                    pos += 1
                else:
                    pad += 8
                bitcnt += 8
            e = dt[bitbuf & dmask]
            if e < 0:
                raise InflateError("invalid distance code")
            l = e >> 16
            if l > bitcnt - pad:
                raise InflateError("truncated")
            bitbuf >>= l
            bitcnt -= l
            dsym = e & 0xFFFF
            if dsym >= 30:
                raise InflateError("invalid distance code")
            dist = DBASE[dsym] + getbits(DEXT[dsym])
            cur = len(out)
            if dist > cur:
                raise InflateError("distance too far back")
            if dist > maxdist:
                maxdist = dist
            if length > maxlen:
                maxlen = length
            if dist >= length:
                out += out[cur - dist:cur - dist + length]
            else:
                seg = bytes(out[cur - dist:])
                out += (seg * (length // dist + 1))[:length]
    # Bits left in the final partial byte are padding; any whole byte that
    # was not consumed is trailing garbage.
    if (bitcnt - pad) // 8 + (n - pos) > 0:
        raise InflateError("trailing data")
    if stats is not None:
        stats["max_distance"] = maxdist
        stats["max_length"] = maxlen
    return bytes(out)


def main():
    tokens = sys.stdin.buffer.read().split()
    hexstr = tokens[0].decode("ascii") if tokens else ""
    data = bytes.fromhex(hexstr)
    try:
        result = inflate(data)
    except InflateError:
        sys.stdout.write("error\n")
        return
    sys.stdout.write(result.hex() + "\n")


if __name__ == "__main__":
    main()
