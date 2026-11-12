/**
 * Multiplication.
 *
 * The product of the two 24-bit significands is exact in 48 bits, so no
 * sticky bit is needed; $(REF roundPack, softfloat,rounding) does the rest.
 */
module softfloat.mul;

import softfloat.bits;
import softfloat.rounding;

@safe pure nothrow @nogc:

/// Returns the bit pattern of `a * b`, rounded to nearest-even.
uint mul(uint a, uint b)
{
    if (isNaN(a) || isNaN(b))
        return canonicalNaN;

    immutable sign = signOf(a) != signOf(b);

    if (isInfinity(a) || isInfinity(b))
        return (isZero(a) || isZero(b)) ? canonicalNaN : infinity(sign);
    if (isZero(a) || isZero(b))
        return zero(sign);

    immutable x = unpack(a);
    immutable y = unpack(b);
    immutable ulong product = cast(ulong) x.significand * y.significand;
    return roundPack(sign, x.exponent + y.exponent, product);
}

unittest
{
    assert(mul(0x4040_0000, 0xc040_0000) == 0xc110_0000); // 3 * -3
    assert(mul(0x7f80_0000, 0) == canonicalNaN);
    assert(mul(0, 0x7f80_0000) == canonicalNaN);
    assert(mul(0, 0xbf80_0000) == 0x8000_0000);
    assert(mul(0x8000_0000, 0x8000_0000) == 0);
    assert(mul(0xff80_0000, 0xbf80_0000) == 0x7f80_0000);
    assert(mul(0x7fc0_0001, 0x3f80_0000) == canonicalNaN);
    // -2^-150 rounds to -0; 2^-149 * 0.5 is a tie that rounds to +0
    assert(mul(0x8000_0001, 0x3f00_0000) == 0x8000_0000);
    assert(mul(0x0000_0001, 0x3f00_0000) == 0);
    // 3 * 2^-149 * 0.5 = 1.5 * 2^-149 -> 2 * 2^-149
    assert(mul(0x0000_0003, 0x3f00_0000) == 0x0000_0002);
    // overflow
    assert(mul(0x7f7f_ffff, 0x4000_0000) == 0x7f80_0000);
    // denormal * large normal gives a normal result
    assert(mul(0x0000_0001, 0x7e80_0000) == 0x3400_0000); // 2^-149 * 2^126 = 2^-23
}
