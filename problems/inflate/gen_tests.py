#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the inflate problem.

Valid streams come from zlib (raw DEFLATE, wbits=-15, various levels and
strategies) and from a small hand-written encoder that can produce block
shapes zlib never emits (empty distance code, single 1-bit codes, 15-bit
codes, code-length repeats across the literal/distance boundary, ...).
The same encoder also crafts malformed streams. Every valid stream is
cross-checked against zlib and every malformed stream is confirmed to be
rejected (or left incomplete / with unused data) by zlib, and expected
outputs are produced by reference/main.py.
"""
import heapq
import os
import random
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
sys.path.insert(0, os.path.join(HERE, "reference"))
from main import inflate, InflateError  # noqa: E402

LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51,
         59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
LEXT = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
        5, 5, 5, 5, 0]
DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
         513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385,
         24577]
DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10,
        10, 11, 11, 12, 12, 13, 13]
CLEN_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


# --------------------------------------------------------------------------
# Bit-level DEFLATE encoder
# --------------------------------------------------------------------------

class BitWriter:
    def __init__(self):
        self.buf = bytearray()
        self.acc = 0
        self.n = 0

    def bits(self, value, count):
        """Writes count bits of value, least significant bit first."""
        self.acc |= value << self.n
        self.n += count
        while self.n >= 8:
            self.buf.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def code(self, code, length):
        """Writes a Huffman code, most significant bit first."""
        r = 0
        for _ in range(length):
            r = (r << 1) | (code & 1)
            code >>= 1
        self.bits(r, length)

    def align(self):
        if self.n:
            self.bits(0, 8 - self.n)

    def finish(self):
        self.align()
        return bytes(self.buf)


def canonical_codes(lengths):
    """Returns {symbol: (code, length)} per RFC 1951 3.2.2."""
    maxbits = max(lengths) if lengths else 0
    count = [0] * (maxbits + 1)
    for l in lengths:
        if l:
            count[l] += 1
    next_code = [0] * (maxbits + 2)
    code = 0
    for l in range(1, maxbits + 1):
        code = (code + count[l - 1]) << 1
        next_code[l] = code
    codes = {}
    for sym, l in enumerate(lengths):
        if l:
            codes[sym] = (next_code[l], l)
            next_code[l] += 1
    return codes


def huffman_lengths(freqs, limit):
    """Code lengths for the symbols with nonzero frequency, forming a complete
    code of at most limit bits. Uses plain Huffman and falls back to a
    balanced assignment if the limit would be exceeded."""
    used = [s for s, f in enumerate(freqs) if f > 0]
    lengths = [0] * len(freqs)
    if not used:
        return lengths
    if len(used) == 1:
        # A complete code needs at least two symbols; add a dummy neighbour.
        other = (used[0] + 1) % len(freqs)
        lengths[used[0]] = lengths[other] = 1
        return lengths
    heap = [(freqs[s], i, [s]) for i, s in enumerate(used)]
    heapq.heapify(heap)
    counter = len(used)
    while len(heap) > 1:
        f1, _, s1 = heapq.heappop(heap)
        f2, _, s2 = heapq.heappop(heap)
        for s in s1 + s2:
            lengths[s] += 1
        heapq.heappush(heap, (f1 + f2, counter, s1 + s2))
        counter += 1
    if max(lengths) <= limit:
        return lengths
    # Balanced fallback: n symbols, L = ceil(log2 n); shorten 2^L - n of them
    # by one bit so that the Kraft sum is exactly 1.
    n = len(used)
    L = (n - 1).bit_length()
    extra = (1 << L) - n
    lengths = [0] * len(freqs)
    for i, s in enumerate(used):
        lengths[s] = L - 1 if i < extra else L
    assert L <= limit
    return lengths


def length_symbol(length):
    for i in range(28, -1, -1):
        if length >= LBASE[i]:
            return 257 + i, LEXT[i], length - LBASE[i]
    raise ValueError(length)


def dist_symbol(dist):
    for i in range(29, -1, -1):
        if dist >= DBASE[i]:
            return i, DEXT[i], dist - DBASE[i]
    raise ValueError(dist)


def write_tokens(bw, tokens, litcodes, distcodes):
    """tokens: ints (literals), ('m', length, dist) matches, or ('raw', sym,
    extra_bits, extra_value, dsym, dextra_bits, dextra_value) for hand-picked
    symbol/extra combinations. Ends with the end-of-block code."""
    for t in tokens:
        if isinstance(t, int):
            bw.code(*litcodes[t])
        elif t[0] == "m":
            _, length, dist = t
            sym, eb, ev = length_symbol(length)
            bw.code(*litcodes[sym])
            bw.bits(ev, eb)
            dsym, deb, dev = dist_symbol(dist)
            bw.code(*distcodes[dsym])
            bw.bits(dev, deb)
        else:
            _, sym, eb, ev, dsym, deb, dev = t
            bw.code(*litcodes[sym])
            bw.bits(ev, eb)
            if dsym is not None:
                bw.code(*distcodes[dsym])
                bw.bits(dev, deb)
    bw.code(*litcodes[256])


FIXED_LIT_LENGTHS = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
FIXED_DIST_LENGTHS = [5] * 32
FIXED_LIT = canonical_codes(FIXED_LIT_LENGTHS)
FIXED_DIST = canonical_codes(FIXED_DIST_LENGTHS)


def emit_fixed(bw, final, tokens):
    bw.bits(final, 1)
    bw.bits(1, 2)
    write_tokens(bw, tokens, FIXED_LIT, FIXED_DIST)


def emit_stored(bw, final, data, ln=None, nln=None, body=None):
    """One stored block. ln/nln/body override the encoded fields when crafting
    malformed streams."""
    bw.bits(final, 1)
    bw.bits(0, 2)
    bw.align()
    if ln is None:
        ln = len(data)
    if nln is None:
        nln = ~ln & 0xFFFF
    bw.bits(ln, 16)
    bw.bits(nln, 16)
    bw.buf += data if body is None else body


def emit_stored_chunks(bw, final, data):
    """Splits data into stored blocks of at most 65535 bytes."""
    chunks = [data[i:i + 65535] for i in range(0, len(data), 65535)] or [b""]
    for i, c in enumerate(chunks):
        emit_stored(bw, final and i == len(chunks) - 1, c)


def rle_code_lengths(lengths, use_rle=True):
    """Encodes a list of code lengths as code-length-alphabet symbols:
    (sym, extra_bits, extra_value)."""
    seq = []
    i = 0
    n = len(lengths)
    while i < n:
        v = lengths[i]
        run = 1
        while i + run < n and lengths[i + run] == v:
            run += 1
        if not use_rle:
            seq.append((v, 0, 0))
            i += 1
            continue
        if v == 0 and run >= 3:
            r = min(run, 138)
            if r >= 11:
                seq.append((18, 7, r - 11))
            else:
                seq.append((17, 3, r - 3))
            i += r
        elif v != 0 and run >= 4:
            seq.append((v, 0, 0))
            i += 1
            r = min(run - 1, 6)
            seq.append((16, 2, r - 3))
            i += r
        else:
            seq.append((v, 0, 0))
            i += 1
    return seq


def emit_dynamic_header_raw(bw, hlit, hdist, clen_lengths, clen_seq):
    """Writes HLIT/HDIST/HCLEN, the code-length-code lengths and the
    code-length symbol sequence exactly as given (no validation)."""
    bw.bits(hlit - 257, 5)
    bw.bits(hdist - 1, 5)
    hclen = 19
    while hclen > 4 and clen_lengths[CLEN_ORDER[hclen - 1]] == 0:
        hclen -= 1
    bw.bits(hclen - 4, 4)
    for i in range(hclen):
        bw.bits(clen_lengths[CLEN_ORDER[i]], 3)
    ccodes = canonical_codes(clen_lengths)
    for sym, eb, ev in clen_seq:
        bw.code(*ccodes[sym])
        bw.bits(ev, eb)


def dynamic_header(bw, lit_lengths, dist_lengths, use_rle=True, clen_lengths=None):
    """Writes a dynamic block header for the given code lengths and returns
    the literal and distance code tables."""
    lit_lengths = list(lit_lengths)
    dist_lengths = list(dist_lengths)
    hlit = max(257, len(lit_lengths))
    lit_lengths += [0] * (hlit - len(lit_lengths))
    while hlit > 257 and lit_lengths[hlit - 1] == 0:
        hlit -= 1
    hdist = max(1, len(dist_lengths))
    dist_lengths += [0] * (hdist - len(dist_lengths))
    while hdist > 1 and dist_lengths[hdist - 1] == 0:
        hdist -= 1
    seq = rle_code_lengths(lit_lengths[:hlit] + dist_lengths[:hdist], use_rle)
    if clen_lengths is None:
        freqs = [0] * 19
        for sym, _, _ in seq:
            freqs[sym] += 1
        clen_lengths = huffman_lengths(freqs, 7)
    emit_dynamic_header_raw(bw, hlit, hdist, clen_lengths, seq)
    return canonical_codes(lit_lengths), canonical_codes(dist_lengths)


def emit_dynamic(bw, final, lit_lengths, dist_lengths, tokens, use_rle=True, clen_lengths=None):
    bw.bits(final, 1)
    bw.bits(2, 2)
    lc, dc = dynamic_header(bw, lit_lengths, dist_lengths, use_rle, clen_lengths)
    write_tokens(bw, tokens, lc, dc)


def lz77_tokens(data, window=32768, minmatch=3, maxlen=258):
    """Greedy LZ77 tokenisation with a hash chain; good enough for tests."""
    tokens = []
    i = 0
    n = len(data)
    head = {}
    while i < n:
        best_len = 0
        best_dist = 0
        if i + minmatch <= n:
            key = data[i:i + minmatch]
            for j in reversed(head.get(key, [])):
                if i - j > window:
                    break
                l = 0
                while l < maxlen and i + l < n and data[j + l] == data[i + l]:
                    l += 1
                if l > best_len:
                    best_len, best_dist = l, i - j
                    if l == maxlen:
                        break
        if best_len >= minmatch:
            tokens.append(("m", best_len, best_dist))
            step = best_len
        else:
            tokens.append(data[i])
            step = 1
        for k in range(i, i + step):
            if k + minmatch <= n:
                head.setdefault(data[k:k + minmatch], []).append(k)
        i += step
    return tokens


def tokens_to_lengths(tokens):
    """Frequency-based literal/length and distance code lengths for tokens."""
    lf = [0] * 286
    df = [0] * 30
    lf[256] = 1
    for t in tokens:
        if isinstance(t, int):
            lf[t] += 1
        elif t[0] == "m":
            lf[length_symbol(t[1])[0]] += 1
            df[dist_symbol(t[2])[0]] += 1
        else:
            lf[t[1]] += 1
            if t[4] is not None:
                df[t[4]] += 1
    return huffman_lengths(lf, 15), huffman_lengths(df, 15)


def zdeflate(data, level=6, strategy=zlib.Z_DEFAULT_STRATEGY, memlevel=8):
    c = zlib.compressobj(level, zlib.DEFLATED, -15, memlevel, strategy)
    return c.compress(data) + c.flush()


# --------------------------------------------------------------------------
# Data generators
# --------------------------------------------------------------------------

WORDS = ("the of and to in is you that it he was for on are as with his they I at be this have from or one had by word but not what all were we when your can said there use an each which she do how their if will up other about out many then them these so some her would make like him into time has look two more write go see number no way could people my than first water been call who oil its now find long down day did get come made may part").split()


def synth_text(rng, size):
    parts = []
    total = 0
    while total < size:
        n = rng.randint(4, 14)
        sentence = " ".join(rng.choice(WORDS) for _ in range(n))
        if rng.random() < 0.15:
            sentence += " %d" % rng.randint(0, 99999)
        sentence = sentence[0].upper() + sentence[1:] + rng.choice([". ", ". ", "? ", "!\n"])
        parts.append(sentence)
        total += len(sentence)
    return "".join(parts).encode()[:size]


def synth_binary(rng, size):
    """Struct-like records: fixed header bytes, little-endian counters, noise."""
    out = bytearray()
    counter = 0
    while len(out) < size:
        out += b"\x89REC"
        out += counter.to_bytes(4, "little")
        out += (counter * 7919 % 65536).to_bytes(2, "little")
        out += bytes(rng.getrandbits(8) for _ in range(rng.randint(0, 6)))
        out += bytes([rng.choice([0, 0, 0, 255, 1, 2])] * rng.randint(1, 20))
        counter += 1
    return bytes(out[:size])


def rand_bytes(rng, size):
    return rng.randbytes(size)


# --------------------------------------------------------------------------
# Test registry
# --------------------------------------------------------------------------

cases = []  # (name, stream_bytes, expected_bytes_or_None, needed_stats)


def valid(name, stream, expected, **needed):
    cases.append((name, stream, expected, needed))


def bad(name, stream):
    cases.append((name, stream, None, {}))


def build_cases():
    rng = random.Random(20260920)

    # --- trivial and hand-made -------------------------------------------
    bad("empty_stream", b"")
    valid("empty_data_fixed", zdeflate(b""), b"", blocks=[1])
    bw = BitWriter()
    emit_stored(bw, 1, b"A")
    valid("stored_one_byte", bw.finish(), b"A", blocks=[0])
    bw = BitWriter()
    emit_stored(bw, 1, b"")
    valid("stored_empty_final", bw.finish(), b"", blocks=[0])
    valid("fixed_hello", zdeflate(b"hello"), b"hello", blocks=[1])
    bw = BitWriter()
    emit_fixed(bw, 1, [ord("a"), ord("b"), ord("c"), ("m", 6, 3)])
    valid("fixed_backref", bw.finish(), b"abcabcabc", blocks=[1], max_distance=3)
    bw = BitWriter()
    emit_stored(bw, 0, b"first block ")
    emit_stored(bw, 1, b"second block")
    valid("stored_two_blocks", bw.finish(), b"first block second block", blocks=[0, 0])
    d = rand_bytes(rng, 1000)
    valid("stored_random_1k", zdeflate(d, 0), d, blocks=[0])
    d = synth_text(rng, 600)
    valid("dynamic_text_small", zdeflate(d, 9), d, blocks=[2])

    # Dynamic block, literals only, HDIST=1 with a zero-length distance code.
    d = b"no matches here!"
    lit = [0] * 257
    for c in set(d):
        lit[c] = 5
    lit[256] = 5
    # Make the 5-bit code complete by giving unused literals 5-bit codes too.
    used = sum(1 for l in lit if l)
    for c in range(256):
        if used == 32:
            break
        if lit[c] == 0:
            lit[c] = 5
            used += 1
    bw = BitWriter()
    emit_dynamic(bw, 1, lit, [0], list(d))
    valid("dynamic_no_dist_codes", bw.finish(), d, blocks=[2], empty_dist=True)

    # Single distance code of length 1 (an allowed incomplete code).
    d = b"abcabcabcabcabc"
    tokens = [97, 98, 99, ("m", 12, 3)]
    lit = [0] * 286
    lit[97] = lit[98] = lit[99] = 2
    lit[256] = 3
    lit[265] = 3  # length 12 (base 11, 1 extra bit)
    dist = [0] * 30
    dist[2] = 1  # distance 3
    bw = BitWriter()
    emit_dynamic(bw, 1, lit, dist, tokens)
    valid("dynamic_single_dist_code", bw.finish(), d, blocks=[2], single_dist=True, max_distance=3)

    # Literal/length code consisting only of a 1-bit end-of-block code.
    lit = [0] * 257
    lit[256] = 1
    bw = BitWriter()
    emit_dynamic(bw, 1, lit, [0], [])
    valid("dynamic_only_eob", bw.finish(), b"", blocks=[2], single_lit=True, empty_dist=True)

    # Code-length repeat (16) whose run crosses from the literal/length
    # lengths into the distance lengths. Literal/length symbols 253..260 and
    # distance symbols 0..7 all have 3-bit codes (two complete codes), so the
    # header holds 253 zeros followed by sixteen 3s, which the RLE encoder
    # writes as 18, 18, 3, 16, 16, 16 with the 16s spanning the boundary.
    lit = [0] * 253 + [3] * 8
    dist = [3] * 8
    tokens = [253, 254, 255, ("m", 3, 1), ("m", 4, 2), ("m", 5, 3), ("m", 3, 4),
              253, ("m", 3, 5), ("m", 4, 8)]
    d = bytearray()
    for t in tokens:
        if isinstance(t, int):
            d.append(t)
        else:
            for _ in range(t[1]):
                d.append(d[len(d) - t[2]])
    d = bytes(d)
    bw = BitWriter()
    emit_dynamic(bw, 1, lit, dist, tokens)
    valid("dynamic_repeat16_across_boundary", bw.finish(), d, blocks=[2], clen_codes={16, 18})

    # Code-length codes 17 and 18 with their maximal repeat counts (10 and
    # 138 zeros) and no 16: symbols 0, 139, 245 and 256 have codes of
    # lengths 1, 2, 3, 3 (complete), leaving zero runs of 138, 105 and 10.
    lit = [0] * 257
    lit[0] = 1
    lit[139] = 2
    lit[245] = 3
    lit[256] = 3
    tokens = [0, 139, 245, 0, 0, 139]
    d = bytes(tokens)
    bw = BitWriter()
    emit_dynamic(bw, 1, lit, [0], tokens)
    valid("dynamic_repeat_17_18_max", bw.finish(), d, blocks=[2], clen_codes={17, 18})

    # 15-bit literal/length codes and 15-bit distance codes.
    lit = [0] * 286
    # Kraft-complete: one code per length 1..14 plus two of length 15.
    syms = [256] + list(range(97, 97 + 13)) + [257 + 28, 0]  # 16 symbols
    for i, s in enumerate(syms):
        lit[s] = min(i + 1, 15)
    dist = [0] * 30
    dsyms = list(range(0, 16))
    for i, s in enumerate(dsyms):
        dist[s] = min(i + 1, 15)
    text = bytes(range(97, 110)) + b"\x00"
    tokens = list(text) + [("m", 258, 1), ("m", 258, 14)]
    d = text + text[-1:] * 258
    d += d[-14:] * 18 + d[-14:][:258 - 14 * 18]
    bw = BitWriter()
    emit_dynamic(bw, 1, lit, dist, tokens)
    valid("dynamic_15bit_codes", bw.finish(), d, blocks=[2], max_litlen_bits=15, max_dist_bits=15, max_length=258)

    # Fixed block with length 258 at distance 32768 (both maxima).
    pre = rand_bytes(rng, 32768)
    tokens = list(pre) + [("m", 258, 32768), ("m", 258, 32768)]
    d = pre + pre[:258] + pre[258:516]
    bw = BitWriter()
    emit_fixed(bw, 1, tokens)
    valid("fixed_len258_dist32768", bw.finish(), d, blocks=[1], max_distance=32768, max_length=258)

    # HLIT = 29 (all 286 literal/length codes) and HDIST = 29 (all 30 distance
    # codes) with every code actually used, including symbol 285 and
    # distance symbol 29 at 32768.
    pre = bytes(rng.getrandbits(8) for _ in range(32768))
    tokens = list(pre)
    d = bytearray(pre)
    for i in range(29):
        # Largest length of each symbol; symbol 284 tops out at 257 because
        # 258 belongs to symbol 285.
        length = min(LBASE[i] + ((1 << LEXT[i]) - 1), 257 if i == 27 else 258)
        dist = DBASE[i] + ((1 << DEXT[i]) - 1)
        tokens.append(("m", length, dist))
        for _ in range(length):
            d.append(d[len(d) - dist])
    # distance symbol 29 with full extra bits = 32768
    tokens.append(("m", 258, 32768))
    for _ in range(258):
        d.append(d[len(d) - 32768])
    lit_l, dist_l = tokens_to_lengths(tokens)
    assert sum(1 for l in lit_l if l) == 286 and sum(1 for l in dist_l if l) == 30
    bw = BitWriter()
    emit_dynamic(bw, 1, lit_l, dist_l, tokens)
    valid("dynamic_hlit29_hdist29", bw.finish(), bytes(d), blocks=[2], hlit_max=286, hdist_max=30, max_distance=32768, max_length=258)

    # Mixed block types with back-references crossing block boundaries and a
    # stored block that forces byte alignment mid-stream.
    a = synth_text(rng, 700)
    b = rand_bytes(rng, 300)
    tokens = [("m", 200, 1000), ("m", 100, 500), ("m", 200, 1000)]
    c = a[:200] + b[:100] + a[300:500]
    bw = BitWriter()
    emit_fixed(bw, 0, lz77_tokens(a))
    emit_stored(bw, 0, b)
    lit_l, dist_l = tokens_to_lengths(tokens)
    emit_dynamic(bw, 0, lit_l, dist_l, tokens)
    emit_fixed(bw, 1, [])
    valid("mixed_block_types", bw.finish(), a + b + c, blocks=[1, 0, 2, 1])

    # Non-final empty blocks of each type followed by a final block.
    bw = BitWriter()
    emit_fixed(bw, 0, [])
    emit_stored(bw, 0, b"")
    emit_dynamic(bw, 0, [0] * 256 + [1], [0], [])
    emit_fixed(bw, 1, list(b"end"))
    valid("empty_nonfinal_blocks", bw.finish(), b"end", blocks=[1, 0, 2, 1])

    # Dynamic header with no run-length codes at all (every length literal).
    d = synth_text(rng, 300)
    tokens = lz77_tokens(d)
    lit_l, dist_l = tokens_to_lengths(tokens)
    bw = BitWriter()
    emit_dynamic(bw, 1, lit_l, dist_l, tokens, use_rle=False)
    valid("dynamic_no_rle_lengths", bw.finish(), d, blocks=[2], clen_codes=set())

    # Overlapping copies: distance 1 and 2 with long lengths (run-length style).
    d = b"x" * 1000 + b"yz" * 500 + b"abc" * 333
    valid("overlapping_copies", zdeflate(d, 9), d, max_length=258)

    # Length symbol 284 with all five extra bits set encodes 258, the same
    # length as symbol 285; strict decoders that reject it are wrong.
    bw = BitWriter()
    emit_fixed(bw, 1, [ord("a"), ("raw", 284, 5, 31, 0, 0, 0)])
    valid("fixed_len_sym284_extra31", bw.finish(), b"a" * 259, blocks=[1], max_length=258)

    # Code-length symbol 16 directly after a 17 run repeats the zero that the
    # run produced, not the last literal length before it. The header holds
    # 2, 17x3, 16x3, 2, 2, 18x138, 18x109, 2 (literal/length symbols 0, 7, 8
    # and 256 get 2-bit codes: complete) and one zero distance length.
    lit = [0] * 257
    lit[0] = lit[7] = lit[8] = lit[256] = 2
    cl = [0] * 19
    cl[0] = cl[2] = cl[16] = 2
    cl[17] = cl[18] = 3
    seq = [(2, 0, 0), (17, 3, 0), (16, 2, 0), (2, 0, 0), (2, 0, 0),
           (18, 7, 138 - 11), (18, 7, 109 - 11), (2, 0, 0), (0, 0, 0)]
    tokens = [0, 7, 8, 0, 7, 8, 8]
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(2, 2)
    emit_dynamic_header_raw(bw, 257, 1, cl, seq)
    write_tokens(bw, tokens, canonical_codes(lit), {})
    valid("dynamic_repeat16_after_zero_run", bw.finish(), bytes(tokens), blocks=[2], clen_codes={16, 17, 18})

    # A stored block whose 3-bit header ends exactly on a byte boundary, so
    # the skip to the next boundary discards nothing (37 bits of fixed block:
    # three 9-bit literals plus header and end-of-block, then 3 header bits).
    bw = BitWriter()
    emit_fixed(bw, 0, [200, 201, 202])
    emit_stored(bw, 1, b"xyz")
    assert len(bw.buf) == 5 + 4 + 3
    valid("stored_header_on_byte_boundary", bw.finish(), bytes([200, 201, 202]) + b"xyz", blocks=[1, 0])

    # Unused bits are not checked: the leftover bits of the final byte and
    # the bits discarded before a stored block's LEN may be nonzero.
    raw = bytearray(zdeflate(b"abc"))  # 34 bits used, 6 padding bits
    raw[-1] |= 0xFC
    valid("fixed_nonzero_padding_bits", bytes(raw), b"abc", blocks=[1])
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(0, 2)
    bw.bits(0x1F, 5)  # discarded before LEN
    bw.bits(3, 16)
    bw.bits(~3 & 0xFFFF, 16)
    bw.buf += b"abc"
    valid("stored_nonzero_discarded_bits", bw.finish(), b"abc", blocks=[0])

    # --- zlib at assorted levels / strategies ------------------------------
    d = synth_text(rng, 20000)
    valid("zlib_level1_text", zdeflate(d, 1), d)
    d = synth_binary(rng, 30000)
    valid("zlib_level6_binary", zdeflate(d, 6), d)
    d = synth_text(rng, 50000)
    valid("zlib_huffman_only", zdeflate(d, 9, zlib.Z_HUFFMAN_ONLY), d)
    d = bytes(rng.choice([0, 0, 0, 1, 1, 2, 3, 250]) for _ in range(3000)) * 10
    valid("zlib_rle_strategy", zdeflate(d, 9, zlib.Z_RLE), d)
    d = synth_text(rng, 40000)
    valid("zlib_fixed_strategy", zdeflate(d, 9, zlib.Z_FIXED), d, blocks=[1])
    d = synth_binary(rng, 40000)
    valid("zlib_filtered_strategy", zdeflate(d, 6, zlib.Z_FILTERED), d)
    d = rand_bytes(rng, 200000)
    valid("zlib_stored_multi_block", zdeflate(d, 0), d, blocks=lambda b: len(b) >= 4 and set(b) == {0})
    d = rand_bytes(rng, 100000)
    valid("zlib_random_level9", zdeflate(d, 9), d)
    d = synth_text(rng, 100000)
    valid("zlib_level9_text_multi_block", zdeflate(d, 9, memlevel=1), d)
    # zlib itself never emits distances above 32506 (window minus lookahead);
    # the exact 32768 maximum is exercised by the hand-made tests 016/017.
    period = rand_bytes(rng, 32500)
    d = period * 4
    valid("zlib_near_max_distance_period", zdeflate(d, 9), d, max_distance=32500)

    # --- malformed -----------------------------------------------------------
    good = zdeflate(synth_text(rng, 2000), 9)
    bad("err_truncated_dynamic_mid_data", good[:len(good) // 2])
    bad("err_truncated_dynamic_header", good[:5])
    fixed_good = zdeflate(b"hello hello hello hello", 9, zlib.Z_FIXED)
    bad("err_truncated_fixed", fixed_good[:-2])
    bw = BitWriter()
    emit_stored(bw, 1, b"0123456789", body=b"01234")
    bad("err_truncated_stored", bw.finish())
    bw = BitWriter()
    emit_stored(bw, 1, b"abc", nln=0x1234)
    bad("err_stored_len_mismatch", bw.finish())
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(3, 2)
    bw.bits(0, 13)
    bad("err_bad_block_type", bw.finish())
    bw = BitWriter()
    emit_fixed(bw, 1, [ord("a"), ("m", 3, 2)])
    bad("err_distance_too_far", bw.finish())
    bw = BitWriter()
    emit_fixed(bw, 1, [("m", 3, 1)])
    bad("err_distance_before_any_output", bw.finish())
    bw = BitWriter()
    emit_fixed(bw, 1, [ord("a"), ("raw", 257, 0, 0, 30, 0, 0)])
    bad("err_fixed_distance_code_30", bw.finish())
    bw = BitWriter()
    emit_fixed(bw, 1, [ord("a"), ("raw", 286, 0, 0, None, 0, 0)])
    bad("err_fixed_litlen_286", bw.finish())
    # Truncation inside a stored block's LEN/NLEN header.
    bw = BitWriter()
    emit_stored(bw, 1, b"abc")
    bad("err_truncated_stored_header", bw.finish()[:3])
    # Non-final block completes, then the stream ends.
    bw = BitWriter()
    emit_fixed(bw, 0, list(b"abc"))
    bad("err_no_final_block", bw.finish())
    # Valid stream followed by an extra byte.
    bad("err_trailing_byte", zdeflate(b"abc") + b"\x00")

    # HLIT = 30 / HDIST = 30 are forbidden even with otherwise valid tables.
    lit = [0] * 286
    lit[256] = 1
    for hl, hd, name in [(287, 1, "err_hlit_30"), (257, 31, "err_hdist_31")]:
        bw = BitWriter()
        bw.bits(1, 1)
        bw.bits(2, 2)
        clen = [0] * 19
        clen[0] = clen[1] = 1
        seq = [(0, 0, 0)] * (hl + hd)
        seq[256] = (1, 0, 0)
        emit_dynamic_header_raw(bw, hl, hd, clen, seq)
        bw.code(0, 1)  # end of block
        bad(name, bw.finish())

    # Code-length code over-subscribed / incomplete.
    for name, clen in [("err_clen_oversubscribed", {0: 1, 1: 1, 16: 1}),
                       ("err_clen_incomplete", {0: 2, 1: 2, 16: 2})]:
        bw = BitWriter()
        bw.bits(1, 1)
        bw.bits(2, 2)
        cl = [0] * 19
        for k, v in clen.items():
            cl[k] = v
        seq = [(0, 0, 0)] * 257 + [(1, 0, 0)] + [(0, 0, 0)]
        emit_dynamic_header_raw(bw, 257, 1, cl, seq)
        bw.bits(0, 16)
        bad(name, bw.finish())

    # Repeat code 16 as the very first code length. The rest of the stream is
    # valid (symbols 3 and 256 get 1-bit codes, body 3 3 3 EOB), so treating
    # the first 16 as "repeat zero" would decode it.
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(2, 2)
    cl = [0] * 19
    cl[0] = cl[1] = cl[16] = cl[18] = 2
    seq = [(16, 2, 0), (1, 0, 0), (18, 7, 138 - 11), (18, 7, 114 - 11), (1, 0, 0), (0, 0, 0)]
    emit_dynamic_header_raw(bw, 257, 1, cl, seq)
    lit = [0] * 257
    lit[3] = lit[256] = 1
    write_tokens(bw, [3, 3, 3], canonical_codes(lit), {})
    bad("err_repeat16_first", bw.finish())
    # Repeat 18 running past HLIT + HDIST.
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(2, 2)
    cl = [0] * 19
    cl[1] = cl[18] = 1
    emit_dynamic_header_raw(bw, 257, 1, cl, [(18, 7, 127)] + [(18, 7, 127)])
    bw.bits(0, 16)
    bad("err_repeat_overflow", bw.finish())
    # Literal/length code over-subscribed (three 1-bit codes).
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(2, 2)
    cl = [0] * 19
    cl[0] = cl[1] = 1
    seq = [(0, 0, 0)] * 258
    seq[97] = seq[98] = seq[256] = (1, 0, 0)
    emit_dynamic_header_raw(bw, 257, 1, cl, seq)
    bw.bits(0, 1)  # a decoder whose table lets 256 overwrite 97 sees an EOB here
    bad("err_litlen_oversubscribed", bw.finish())
    # Literal/length code incomplete with two codes (lengths 1 and 2).
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(2, 2)
    cl = [0] * 19
    cl[0] = 1
    cl[1] = cl[2] = 2
    seq = [(0, 0, 0)] * 258
    seq[97] = (1, 0, 0)
    seq[256] = (2, 0, 0)
    emit_dynamic_header_raw(bw, 257, 1, cl, seq)
    lit = [0] * 257
    lit[97] = 1
    lit[256] = 2
    # Body a a EOB uses only codes that exist, so a lenient decoder prints 6161.
    write_tokens(bw, [97, 97], canonical_codes(lit), {})
    bad("err_litlen_incomplete", bw.finish())
    # No end-of-block code in the literal/length set.
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(2, 2)
    cl = [0] * 19
    cl[0] = cl[1] = 1
    seq = [(0, 0, 0)] * 258
    seq[97] = seq[98] = (1, 0, 0)
    emit_dynamic_header_raw(bw, 257, 1, cl, seq)
    bw.bits(0, 16)
    bad("err_missing_eob", bw.finish())
    # Distance code over-subscribed / incomplete (two codes 1 and 2 bits).
    # The literal/length set (97 -> 1 bit, 256 and 257 -> 2 bits) is complete
    # and the body a a a <len 3, dist code "0"> EOB only uses the distance
    # code "0", so a decoder that skips the distance-set check prints
    # 616161616161 (with any of the candidate symbols for that bit).
    for name, dl in [("err_dist_oversubscribed", [1, 1, 1]),
                     ("err_dist_incomplete", [1, 2])]:
        bw = BitWriter()
        bw.bits(1, 1)
        bw.bits(2, 2)
        cl = [0] * 19
        cl[0] = 1
        cl[1] = cl[2] = 2
        seq = [(0, 0, 0)] * 258 + [(l, 0, 0) for l in dl]
        seq[97] = (1, 0, 0)
        seq[256] = seq[257] = (2, 0, 0)
        emit_dynamic_header_raw(bw, 258, len(dl), cl, seq)
        lit = [0] * 258
        lit[97] = 1
        lit[256] = lit[257] = 2
        lc = canonical_codes(lit)
        for t in [97, 97, 97]:
            bw.code(*lc[t])
        bw.code(*lc[257])
        bw.bits(0, 1)  # distance code "0"
        bw.code(*lc[256])
        bad(name, bw.finish())
    # Length code used while the distance code set is empty.
    lit = [0] * 286
    lit[97] = 1
    lit[256] = 2
    lit[257] = 2
    bw = BitWriter()
    emit_dynamic(bw, 1, lit, [0], [97, 97, 97, ("raw", 257, 0, 0, None, 0, 0)])
    bad("err_length_with_no_dist_codes", bw.finish())
    # Single 1-bit distance code but the stream uses bit pattern "1".
    lit = [0] * 286
    lit[97] = 1
    lit[256] = 2
    lit[257] = 2
    dist = [1]
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(2, 2)
    lc, dc = dynamic_header(bw, lit, dist)
    bw.code(*lc[97])
    bw.code(*lc[97])
    bw.code(*lc[97])
    bw.code(*lc[257])
    bw.bits(1, 1)  # invalid distance code
    bw.code(*lc[256])
    bad("err_single_dist_code_wrong_bit", bw.finish())
    # Single 1-bit literal/length code (end-of-block) but the body is the bit
    # pattern "1", which is not a code.
    lit = [0] * 257
    lit[256] = 1
    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(2, 2)
    dynamic_header(bw, lit, [0])
    bw.bits(1, 1)
    bad("err_single_litlen_code_wrong_bit", bw.finish())
    # Distance too far back in a dynamic block with a large distance.
    d = synth_text(rng, 500)
    tokens = lz77_tokens(d) + [("m", 10, 600)]
    lit_l, dist_l = tokens_to_lengths(tokens)
    bw = BitWriter()
    emit_dynamic(bw, 1, lit_l, dist_l, tokens)
    bad("err_dynamic_distance_too_far", bw.finish())
    # Truncated in the middle of the extra bits of a distance.
    bw = BitWriter()
    emit_fixed(bw, 0, list(rand_bytes(rng, 5000)) + [("m", 100, 4000)])
    raw = bw.finish()
    bad("err_truncated_in_extra_bits", raw[:-1])
    # Trailing byte after a final block whose end-of-block code starts on a
    # byte boundary (a decoder that peeks ahead has already loaded the extra
    # byte when it finishes) and after a final stored block.
    bw = BitWriter()
    emit_fixed(bw, 1, [200, 201, 202, 203, 204])
    raw = bw.finish()
    assert len(raw) == 7
    bad("err_trailing_byte_after_aligned_eob", raw + b"\x00")
    bw = BitWriter()
    emit_stored(bw, 1, b"abc")
    bad("err_trailing_byte_after_stored", bw.finish() + b"\x00")
    # Fixed distance code 30 is invalid even when 32769 bytes are available
    # (a 32-entry distance table extrapolating base 32769 would accept it).
    bw = BitWriter()
    emit_stored(bw, 0, b"\x5a" * 40000)
    emit_fixed(bw, 1, [("raw", 257, 0, 0, 30, 14, 0)])
    bad("err_fixed_distance_code_30_enough_output", bw.finish())
    bw = BitWriter()
    emit_stored(bw, 0, b"\x5a" * 50000)
    emit_fixed(bw, 1, [("raw", 257, 0, 0, 31, 14, 0)])
    bad("err_fixed_distance_code_31_enough_output", bw.finish())
    # A single code is only accepted as an incomplete set when it is 1 bit
    # long: a lone 2-bit distance code or a lone 2-bit end-of-block code is
    # an error.
    lit = [0] * 286
    lit[97] = 1
    lit[256] = 2
    lit[257] = 2
    bw = BitWriter()
    emit_dynamic(bw, 1, lit, [2], [97, 97, 97, ("m", 3, 1)])
    bad("err_single_dist_code_length_2", bw.finish())
    lit = [0] * 257
    lit[256] = 2
    bw = BitWriter()
    emit_dynamic(bw, 1, lit, [0], [])
    bad("err_single_litlen_code_length_2", bw.finish())

    # --- large ---------------------------------------------------------------
    d = synth_text(rng, 1 << 20)
    valid("large_text_1mb_level9", zdeflate(d, 9), d)
    d = (b"abcabcabd" * 200000)[:1 << 20]
    valid("large_repetitive_1mb", zdeflate(d, 9), d, max_length=258)
    d = rand_bytes(rng, 1 << 20)
    valid("large_random_1mb_stored", zdeflate(d, 6), d, blocks=lambda b: len(b) >= 17 and set(b) == {0})
    d = synth_binary(rng, 512 * 1024)
    valid("large_binary_512k_level6", zdeflate(d, 6), d)
    period = rand_bytes(rng, 32500)
    d = (period * 40)[:1 << 20]
    valid("large_near_max_distance_1mb", zdeflate(d, 9), d, max_distance=32500)
    d = synth_text(rng, 1 << 20)
    valid("large_huffman_only_1mb", zdeflate(d, 9, zlib.Z_HUFFMAN_ONLY), d)
    d = synth_text(rng, 512 * 1024)
    valid("large_fixed_strategy_512k", zdeflate(d, 9, zlib.Z_FIXED), d, blocks=lambda b: set(b) == {1})
    d = bytes(rng.choice([7, 7, 7, 7, 9, 200]) for _ in range(20000)) * 50
    valid("large_rle_1mb", zdeflate(d, 9, zlib.Z_RLE), d)
    d = synth_text(rng, 700 * 1024)
    valid("large_level1_memlevel1_many_blocks", zdeflate(d, 1, memlevel=1), d)


# --------------------------------------------------------------------------
# Cross-checks and output
# --------------------------------------------------------------------------

def zlib_full_decode(stream):
    """Returns (ok, output). ok is True only if zlib consumes the whole stream
    as one complete DEFLATE stream with nothing left over."""
    d = zlib.decompressobj(-15)
    try:
        out = d.decompress(stream) + d.flush()
    except zlib.error:
        return False, None
    if not d.eof or d.unused_data:
        return False, out
    return True, out


def reference_cli(stream):
    p = subprocess.run([sys.executable, os.path.join(HERE, "reference", "main.py")],
                       input=(stream.hex() + "\n").encode(), capture_output=True, check=True)
    return p.stdout.decode().strip()


def main():
    build_cases()
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        os.remove(os.path.join(TESTS, f))
    # Tests are numbered in definition order, which is also difficulty order.
    cases[:] = [("%03d_%s" % (i + 1, name), stream, expected, needed)
                for i, (name, stream, expected, needed) in enumerate(cases)]
    names = [c[0] for c in cases]
    assert len(names) == len(set(names))
    total_in = total_out = 0
    for name, stream, expected, needed in cases:
        stats = {}
        try:
            got = inflate(stream, stats)
        except InflateError as e:
            got = None
            err = str(e)
        zok, zout = zlib_full_decode(stream)
        if expected is None:
            assert got is None, f"{name}: reference accepted a malformed stream"
            assert not zok, f"{name}: zlib accepted a stream meant to be malformed"
            out_text = "error"
        else:
            assert got == expected, f"{name}: reference output differs from expected"
            assert zok and zout == expected, f"{name}: zlib disagrees with expected"
            out_text = expected.hex()
            for key, want in needed.items():
                have = stats.get(key)
                if callable(want):
                    assert want(have), f"{name}: stats {key} = {have} fails check"
                else:
                    assert have == want, f"{name}: stats {key} = {have}, want {want}"
        assert reference_cli(stream) == out_text, f"{name}: CLI output mismatch"
        in_text = stream.hex() + "\n"
        with open(os.path.join(TESTS, name + ".in"), "w") as f:
            f.write(in_text)
        with open(os.path.join(TESTS, name + ".out"), "w") as f:
            f.write(out_text + "\n")
        total_in += len(in_text)
        total_out += len(out_text) + 1
        print(f"{name}: in={len(stream)}B out={'error' if expected is None else str(len(expected)) + 'B'} "
              f"blocks={len(stats.get('blocks', []))}:{sorted(set(stats.get('blocks', [])))} maxdist={stats.get('max_distance')} clen={sorted(stats.get('clen_codes', []))}")
    print(f"{len(cases)} tests, {total_in / 1e6:.1f} MB of .in, {total_out / 1e6:.1f} MB of .out")


if __name__ == "__main__":
    main()
