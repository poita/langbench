#!/usr/bin/env python3
"""Software IEEE-754 binary32 arithmetic (add, sub, mul, div, sqrt).

Every operation is computed with exact integer arithmetic and then rounded
once to nearest-even. No host floating-point operation is used anywhere, so
this file is the oracle for the expected outputs.
"""
import sys
from math import isqrt

QNAN = 0x7FC00000
INF = 0x7F800000
HIDDEN = 1 << 23
# Weight (as a power of two) of the least significant bit of a denormal.
DENORM_LSB_EXP = -149

# Extra quotient bits for div and sqrt. The truncated result carries a sticky
# bit in position 0, which only rounds correctly if it sits at least two bits
# below the rounding position; 60 (resp. 40) bits leave a wide margin.
DIV_EXTRA_BITS = 60
SQRT_EXTRA_BITS = 40


def unpack(bits):
    """Returns (kind, sign, mantissa, exp) with value = mantissa * 2**exp.

    kind is one of 'nan', 'inf', 'zero', 'fin'. For 'fin' the mantissa is the
    integer significand (hidden bit included for normals) and exp is the weight
    of its least significant bit.
    """
    sign = bits >> 31
    biased = (bits >> 23) & 0xFF
    frac = bits & 0x7FFFFF
    if biased == 0xFF:
        return ("nan" if frac else "inf", sign, 0, 0)
    if biased == 0:
        if frac == 0:
            return ("zero", sign, 0, 0)
        return ("fin", sign, frac, DENORM_LSB_EXP)
    return ("fin", sign, frac | HIDDEN, biased - 127 - 23)


def round_pack(sign, m, e):
    """Rounds sign * m * 2**e (m > 0) to the nearest-even binary32 bit pattern.

    m may be exact, or a truncated value whose bit 0 is a sticky bit; in the
    latter case m must have at least 26 significant bits.
    """
    if m == 0:
        return sign << 31
    length = m.bit_length()
    lead_exp = e + length - 1
    normal = lead_exp >= -126
    if normal:
        shift = length - 24
    else:
        shift = DENORM_LSB_EXP - e
    if shift > 0:
        q = m >> shift
        rem = m & ((1 << shift) - 1)
        half = 1 << (shift - 1)
        if rem > half or (rem == half and (q & 1)):
            q += 1
    else:
        q = m << (-shift)
    if normal:
        if q == 1 << 24:
            q >>= 1
            lead_exp += 1
        if lead_exp > 127:
            return (sign << 31) | INF
        return (sign << 31) | ((lead_exp + 127) << 23) | (q - HIDDEN)
    # Denormal result: q <= 2**23, and q == 2**23 is exactly the encoding of
    # the smallest normal, so the bit pattern is q itself.
    return (sign << 31) | q


def f_add(a, b):
    ka, sa, ma, ea = unpack(a)
    kb, sb, mb, eb = unpack(b)
    if ka == "nan" or kb == "nan":
        return QNAN
    if ka == "inf" and kb == "inf":
        return a if sa == sb else QNAN
    if ka == "inf":
        return a
    if kb == "inf":
        return b
    if ka == "zero" and kb == "zero":
        # -0 + -0 = -0; any other combination of zeros is +0.
        return (sa & sb) << 31
    if ka == "zero":
        return b
    if kb == "zero":
        return a
    if ea < eb:
        mb <<= eb - ea
        e = ea
    else:
        ma <<= ea - eb
        e = eb
    v = (-ma if sa else ma) + (-mb if sb else mb)
    if v == 0:
        # Exact cancellation of opposite-signed operands is +0 under
        # round-to-nearest.
        return 0
    return round_pack(1 if v < 0 else 0, abs(v), e)


def f_sub(a, b):
    return f_add(a, b ^ 0x80000000)


def f_mul(a, b):
    ka, sa, ma, ea = unpack(a)
    kb, sb, mb, eb = unpack(b)
    sign = sa ^ sb
    if ka == "nan" or kb == "nan":
        return QNAN
    if ka == "inf" or kb == "inf":
        if ka == "zero" or kb == "zero":
            return QNAN
        return (sign << 31) | INF
    if ka == "zero" or kb == "zero":
        return sign << 31
    return round_pack(sign, ma * mb, ea + eb)


def f_div(a, b):
    ka, sa, ma, ea = unpack(a)
    kb, sb, mb, eb = unpack(b)
    sign = sa ^ sb
    if ka == "nan" or kb == "nan":
        return QNAN
    if ka == "inf":
        return QNAN if kb == "inf" else (sign << 31) | INF
    if kb == "inf":
        return sign << 31
    if kb == "zero":
        return QNAN if ka == "zero" else (sign << 31) | INF
    if ka == "zero":
        return sign << 31
    q, r = divmod(ma << DIV_EXTRA_BITS, mb)
    if r:
        q |= 1
    return round_pack(sign, q, ea - eb - DIV_EXTRA_BITS)


def f_sqrt(a):
    ka, sa, ma, ea = unpack(a)
    if ka == "nan":
        return QNAN
    if ka == "zero":
        return a
    if sa:
        return QNAN
    if ka == "inf":
        return a
    if ea & 1:
        ma <<= 1
        ea -= 1
    target = ma << (2 * SQRT_EXTRA_BITS)
    s = isqrt(target)
    if s * s != target:
        s |= 1
    return round_pack(0, s, ea // 2 - SQRT_EXTRA_BITS)


OPS = {"add": f_add, "sub": f_sub, "mul": f_mul, "div": f_div}


def main():
    out = []
    for line in sys.stdin.buffer.read().split(b"\n"):
        parts = line.split()
        if not parts:
            continue
        op = parts[0].decode()
        a = int(parts[1], 16)
        if op == "sqrt":
            r = f_sqrt(a)
        else:
            r = OPS[op](a, int(parts[2], 16))
        out.append("%08x" % r)
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))


if __name__ == "__main__":
    main()
