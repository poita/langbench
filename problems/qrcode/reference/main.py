#!/usr/bin/env python3
"""QR code encoder (ISO/IEC 18004 model 2), stdin -> stdout.

Each input line is "<ecl> <mask> <text>". The output for each line is
"version <v> mask <m>", the symbol as rows of '#' (dark) and '.' (light),
and a blank line.
"""
import re
import sys

# Error correction level index (row in the tables below) and its 2-bit format code.
ECL_INDEX = {"L": 0, "M": 1, "Q": 2, "H": 3}
ECL_FORMAT_BITS = {"L": 1, "M": 0, "Q": 3, "H": 2}

# Error correction codewords per block, indexed [ecl][version].
ECC_CODEWORDS_PER_BLOCK = [
    [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
]

# Number of error correction blocks, indexed [ecl][version].
NUM_ECC_BLOCKS = [
    [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
]

ALNUM_CHARS = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
DIGITS = b"0123456789"

MODE_NUMERIC, MODE_ALNUM, MODE_BYTE = 1, 2, 4
# Character count indicator width for version groups 1-9, 10-26, 27-40.
CC_BITS = {MODE_NUMERIC: (10, 12, 14), MODE_ALNUM: (9, 11, 13), MODE_BYTE: (8, 16, 16)}

PENALTY_N1, PENALTY_N2, PENALTY_N3, PENALTY_N4 = 3, 3, 40, 10


# ---------------------------------------------------------------- bit stream

class BitBuffer:
    def __init__(self):
        self.bits = []

    def append(self, value, nbits):
        for i in range(nbits - 1, -1, -1):
            self.bits.append((value >> i) & 1)

    def __len__(self):
        return len(self.bits)


def select_mode(text):
    if all(c in DIGITS for c in text):
        return MODE_NUMERIC
    if all(c in ALNUM_CHARS for c in text):
        return MODE_ALNUM
    return MODE_BYTE


def cc_bits(mode, version):
    group = 0 if version <= 9 else (1 if version <= 26 else 2)
    return CC_BITS[mode][group]


def data_bits_for_mode(mode, text):
    n = len(text)
    if mode == MODE_NUMERIC:
        return 10 * (n // 3) + (0, 4, 7)[n % 3]
    if mode == MODE_ALNUM:
        return 11 * (n // 2) + 6 * (n % 2)
    return 8 * n


def encode_segment(mode, text, version):
    bb = BitBuffer()
    bb.append(mode, 4)
    bb.append(len(text), cc_bits(mode, version))
    if mode == MODE_NUMERIC:
        for i in range(0, len(text), 3):
            chunk = text[i:i + 3]
            bb.append(int(chunk), (0, 4, 7, 10)[len(chunk)])
    elif mode == MODE_ALNUM:
        for i in range(0, len(text), 2):
            chunk = text[i:i + 2]
            if len(chunk) == 2:
                bb.append(ALNUM_CHARS.index(chunk[0]) * 45 + ALNUM_CHARS.index(chunk[1]), 11)
            else:
                bb.append(ALNUM_CHARS.index(chunk[0]), 6)
    else:
        for b in text:
            bb.append(b, 8)
    return bb


# ---------------------------------------------------------------- capacity

def num_raw_data_modules(version):
    result = (16 * version + 128) * version + 64
    if version >= 2:
        num_align = version // 7 + 2
        result -= (25 * num_align - 10) * num_align - 55
        if version >= 7:
            result -= 36
    return result


def num_data_codewords(version, ecl):
    e = ECL_INDEX[ecl]
    return num_raw_data_modules(version) // 8 - ECC_CODEWORDS_PER_BLOCK[e][version] * NUM_ECC_BLOCKS[e][version]


def select_version(mode, text, ecl):
    for version in range(1, 41):
        needed = 4 + cc_bits(mode, version) + data_bits_for_mode(mode, text)
        if needed <= num_data_codewords(version, ecl) * 8:
            return version
    raise ValueError("data too long for any version")


# ---------------------------------------------------------------- Reed-Solomon over GF(256)

def gf_mul(a, b):
    z = 0
    for i in range(7, -1, -1):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((b >> i) & 1) * a
    return z


def rs_generator(degree):
    # Coefficients of prod_{i=0}^{degree-1} (x - alpha^i), highest degree first, monic.
    result = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = gf_mul(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = gf_mul(root, 2)
    return result


def rs_remainder(data, generator):
    result = [0] * len(generator)
    for b in data:
        factor = b ^ result.pop(0)
        result.append(0)
        for i, coef in enumerate(generator):
            result[i] ^= gf_mul(coef, factor)
    return result


def add_ecc_and_interleave(data, version, ecl):
    e = ECL_INDEX[ecl]
    num_blocks = NUM_ECC_BLOCKS[e][version]
    block_ecc_len = ECC_CODEWORDS_PER_BLOCK[e][version]
    raw_codewords = num_raw_data_modules(version) // 8
    num_short_blocks = num_blocks - raw_codewords % num_blocks
    short_block_len = raw_codewords // num_blocks

    blocks = []
    gen = rs_generator(block_ecc_len)
    k = 0
    for i in range(num_blocks):
        dat_len = short_block_len - block_ecc_len + (0 if i < num_short_blocks else 1)
        dat = data[k:k + dat_len]
        k += dat_len
        ecc = rs_remainder(dat, gen)
        if i < num_short_blocks:
            dat = dat + [None]  # placeholder so all blocks have equal length for interleaving
        blocks.append(dat + ecc)

    result = []
    for i in range(len(blocks[0])):
        for j, blk in enumerate(blocks):
            if i != short_block_len - block_ecc_len or j >= num_short_blocks:
                result.append(blk[i])
    return result


# ---------------------------------------------------------------- matrix

class Matrix:
    def __init__(self, version):
        self.version = version
        self.size = version * 4 + 17
        n = self.size
        self.modules = [[0] * n for _ in range(n)]
        self.is_function = [[False] * n for _ in range(n)]

    def set_function(self, x, y, dark):
        self.modules[y][x] = 1 if dark else 0
        self.is_function[y][x] = True

    def draw_function_patterns(self):
        n = self.size
        # Timing patterns.
        for i in range(n):
            self.set_function(6, i, i % 2 == 0)
            self.set_function(i, 6, i % 2 == 0)
        # Finder patterns with separators.
        self.draw_finder(3, 3)
        self.draw_finder(n - 4, 3)
        self.draw_finder(3, n - 4)
        # Alignment patterns, skipping the three that overlap finders.
        pos = alignment_positions(self.version)
        m = len(pos)
        for i in range(m):
            for j in range(m):
                if (i == 0 and j == 0) or (i == 0 and j == m - 1) or (i == m - 1 and j == 0):
                    continue
                self.draw_alignment(pos[i], pos[j])
        # Reserve format information areas (values are drawn per mask later).
        self.draw_format_bits(0)
        self.draw_version_bits()

    def draw_finder(self, cx, cy):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                dist = max(abs(dx), abs(dy))
                x, y = cx + dx, cy + dy
                if 0 <= x < self.size and 0 <= y < self.size:
                    self.set_function(x, y, dist not in (2, 4))

    def draw_alignment(self, cx, cy):
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                self.set_function(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)

    def draw_format_bits(self, mask):
        data = ECL_FORMAT_BITS[self.ecl] << 3 | mask
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        bits = (data << 10 | rem) ^ 0x5412
        n = self.size
        bit = lambda i: (bits >> i) & 1
        # Around the top-left finder.
        for i in range(6):
            self.set_function(8, i, bit(i))
        self.set_function(8, 7, bit(6))
        self.set_function(8, 8, bit(7))
        self.set_function(7, 8, bit(8))
        for i in range(9, 15):
            self.set_function(14 - i, 8, bit(i))
        # Next to the other two finders.
        for i in range(8):
            self.set_function(n - 1 - i, 8, bit(i))
        for i in range(8, 15):
            self.set_function(8, n - 15 + i, bit(i))
        self.set_function(8, n - 8, True)  # always-dark module

    def draw_version_bits(self):
        if self.version < 7:
            return
        rem = self.version
        for _ in range(12):
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
        bits = self.version << 12 | rem
        n = self.size
        for i in range(18):
            b = (bits >> i) & 1
            a = n - 11 + i % 3
            c = i // 3
            self.set_function(a, c, b)
            self.set_function(c, a, b)

    def draw_codewords(self, codewords):
        n = self.size
        total_bits = len(codewords) * 8
        i = 0
        right = n - 1
        while right >= 1:
            if right == 6:
                right = 5
            for vert in range(n):
                for j in range(2):
                    x = right - j
                    upward = ((right + 1) & 2) == 0
                    y = n - 1 - vert if upward else vert
                    if not self.is_function[y][x] and i < total_bits:
                        self.modules[y][x] = (codewords[i >> 3] >> (7 - (i & 7))) & 1
                        i += 1
            right -= 2

    def masked_rows(self, mask):
        """Return the symbol with `mask` applied to data modules, as a list of row bit-strings."""
        n = self.size
        self.draw_format_bits(mask)
        rows = []
        for y in range(n):
            row = self.modules[y]
            fn = self.is_function[y]
            out = []
            for x in range(n):
                v = row[x]
                if not fn[x] and MASKS[mask](x, y):
                    v ^= 1
                out.append("1" if v else "0")
            rows.append("".join(out))
        return rows


MASKS = [
    lambda x, y: (x + y) % 2 == 0,
    lambda x, y: y % 2 == 0,
    lambda x, y: x % 3 == 0,
    lambda x, y: (x + y) % 3 == 0,
    lambda x, y: (x // 3 + y // 2) % 2 == 0,
    lambda x, y: x * y % 2 + x * y % 3 == 0,
    lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
    lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
]


def alignment_positions(version):
    if version == 1:
        return []
    num_align = version // 7 + 2
    if version == 32:
        step = 26
    else:
        step = (version * 4 + num_align * 2 + 1) // (num_align * 2 - 2) * 2
    size = version * 4 + 17
    result = [6]
    pos = size - 7
    for _ in range(num_align - 1):
        result.insert(1, pos)
        pos -= step
    return result


# ---------------------------------------------------------------- penalty

RUN_RE = re.compile(r"0{5,}|1{5,}")


def penalty_score(rows):
    n = len(rows)
    cols = ["".join(c) for c in zip(*rows)]
    score = 0
    # N1: runs of 5 or more same-colored modules in a row or column.
    # N3: 1:1:3:1:1 finder-like pattern with 4 light modules on one side.
    for line in rows + cols:
        for m in RUN_RE.finditer(line):
            score += PENALTY_N1 + (m.end() - m.start() - 5)
        score += PENALTY_N3 * (line.count("10111010000") + line.count("00001011101"))
    # N2: 2x2 blocks of the same color (overlapping blocks all count).
    ints = [int(r, 2) for r in rows]
    width_mask = (1 << (n - 1)) - 1
    for a, b in zip(ints, ints[1:]):
        dark = a & b & (a >> 1) & (b >> 1) & width_mask
        light = ~a & ~b & ~(a >> 1) & ~(b >> 1) & width_mask
        score += PENALTY_N2 * (bin(dark).count("1") + bin(light).count("1"))
    # N4: deviation of the dark-module proportion from 50%, in 5% steps.
    dark_total = sum(r.count("1") for r in rows)
    total = n * n
    k = abs(20 * dark_total - 10 * total) // total
    score += PENALTY_N4 * k
    return score


# ---------------------------------------------------------------- top level

def encode(ecl, mask_spec, text):
    mode = select_mode(text)
    version = select_version(mode, text, ecl)
    bb = encode_segment(mode, text, version)
    capacity = num_data_codewords(version, ecl) * 8
    bb.append(0, min(4, capacity - len(bb)))
    bb.append(0, (8 - len(bb) % 8) % 8)
    data = [int("".join(map(str, bb.bits[i:i + 8])), 2) for i in range(0, len(bb), 8)]
    pad = 0xEC
    while len(data) * 8 < capacity:
        data.append(pad)
        pad ^= 0xEC ^ 0x11
    codewords = add_ecc_and_interleave(data, version, ecl)

    mat = Matrix(version)
    mat.ecl = ecl
    mat.draw_function_patterns()
    mat.draw_codewords(codewords)

    if mask_spec == "auto":
        best = None
        for m in range(8):
            rows = mat.masked_rows(m)
            s = penalty_score(rows)
            if best is None or s < best[0]:
                best = (s, m, rows)
        _, mask, rows = best
    else:
        mask = int(mask_spec)
        rows = mat.masked_rows(mask)
    return version, mask, rows


def main():
    out = []
    for raw in sys.stdin.buffer.read().split(b"\n"):
        line = raw.rstrip(b"\r")
        if not line:
            continue
        ecl, mask_spec, text = line.split(b" ", 2)
        version, mask, rows = encode(ecl.decode(), mask_spec.decode(), text)
        out.append(f"version {version} mask {mask}")
        for r in rows:
            out.append(r.replace("1", "#").replace("0", "."))
        out.append("")
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
