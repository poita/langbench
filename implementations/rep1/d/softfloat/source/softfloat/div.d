/**
 * Division.
 *
 * One integer division of the (normalised) dividend significand, shifted
 * left, by the divisor significand yields a 39+ bit quotient; a nonzero
 * remainder becomes the sticky bit.  Rounding, including the denormal case,
 * is left entirely to $(REF roundPack, softfloat,rounding), so no double
 * rounding can occur.
 */
module softfloat.div;

import softfloat.bits;
import softfloat.rounding;

@safe pure nothrow @nogc:

/// Returns the bit pattern of `a / b`, rounded to nearest-even.
uint div(uint a, uint b)
{
    if (isNaN(a) || isNaN(b))
        return canonicalNaN;

    immutable sign = signOf(a) != signOf(b);

    if (isInfinity(a))
        return isInfinity(b) ? canonicalNaN : infinity(sign);
    if (isInfinity(b))
        return zero(sign);
    if (isZero(b))
        return isZero(a) ? canonicalNaN : infinity(sign);
    if (isZero(a))
        return zero(sign);

    immutable x = unpackNormalized(a);
    immutable y = unpackNormalized(b);

    // Both significands lie in [2^23, 2^24), so the quotient of
    // (x << 39) / y lies in (2^38, 2^40): at least 39 significant bits.
    enum uint shift = 39;
    immutable ulong dividend = cast(ulong) x.significand << shift;
    immutable ulong divisor = y.significand;
    immutable ulong quotient = dividend / divisor;
    immutable ulong remainder = dividend % divisor;

    immutable ulong sig = (quotient << 1) | (remainder != 0 ? 1 : 0);
    return roundPack(sign, x.exponent - y.exponent - cast(int) shift - 1, sig);
}

unittest
{
    assert(div(0x3f80_0000, 0x4040_0000) == 0x3eaa_aaab); // 1/3
    assert(div(0, 0) == canonicalNaN);
    assert(div(0x7f80_0000, 0x7f80_0000) == canonicalNaN);
    assert(div(0x3f80_0000, 0x8000_0000) == 0xff80_0000);
    assert(div(0, 0xc040_0000) == 0x8000_0000);
    assert(div(0x8000_0000, 0x7f80_0000) == 0x8000_0000);
    assert(div(0x3f80_0000, 0x7f80_0000) == 0);
    assert(div(0x7f80_0000, 0x3f80_0000) == 0x7f80_0000);
    assert(div(0x7fc0_0000, 0x3f80_0000) == canonicalNaN);
    // Ties in the denormal range must round to even only once.
    assert(div(0x0000_0001, 0x4000_0000) == 0);          // 0.5 * 2^-149
    assert(div(0x0000_0003, 0x4000_0000) == 0x0000_0002); // 1.5 * 2^-149
    assert(div(0x0000_0005, 0x4000_0000) == 0x0000_0002); // 2.5 * 2^-149
    // Denormal operands.
    assert(div(0x0000_0001, 0x0000_0001) == 0x3f80_0000);
    assert(div(0x0000_0003, 0x0000_0002) == 0x3fc0_0000);
    assert(div(0x3f80_0000, 0x0000_0001) == 0x7f80_0000);
}
