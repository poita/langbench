/**
 * Square root.
 *
 * After making the exponent even, the scaled significand is run through the
 * restoring digit-by-digit integer square root (at most 31 steps); the final
 * remainder supplies the sticky bit.  The result of a square root is never
 * denormal and never a tie.
 */
module softfloat.sqrt;

import softfloat.bits;
import softfloat.rounding;

@safe pure nothrow @nogc:

/**
 * Restoring digit-by-digit integer square root.
 *
 * Params:
 *   n = radicand
 *   remainder = receives `n - root^2`
 * Returns: floor(sqrt(n))
 */
ulong isqrt(ulong n, out ulong remainder)
{
    ulong rem = n;
    ulong root = 0;
    ulong bit = 1UL << 62; // highest power of four that fits
    while (bit > n && bit != 0)
        bit >>= 2;
    while (bit != 0)
    {
        if (rem >= root + bit)
        {
            rem -= root + bit;
            root = (root >> 1) + bit;
        }
        else
            root >>= 1;
        bit >>= 2;
    }
    remainder = rem;
    return root;
}

/// Returns the bit pattern of `sqrt(a)`, rounded to nearest-even.
uint sqrt(uint a)
{
    if (isNaN(a))
        return canonicalNaN;
    if (isZero(a))
        return a; // sqrt(+-0) = +-0
    if (signOf(a))
        return canonicalNaN; // negative numbers and -infinity
    if (isInfinity(a))
        return a;

    auto x = unpackNormalized(a);
    uint m = x.significand; // in [2^23, 2^24)
    int e = x.exponent;
    if (e & 1) // make the exponent even
    {
        m <<= 1;
        --e;
    }

    // radicand < 2^25 * 2^36 = 2^61, so the root has 30-31 bits.
    enum uint scale = 36;
    ulong rem;
    immutable ulong root = isqrt(cast(ulong) m << scale, rem);
    immutable ulong sig = (root << 1) | (rem != 0 ? 1 : 0);

    // value = root * 2^((e - scale) / 2), and sig carries one extra bit.
    immutable int rootExponent = (e - cast(int) scale) >> 1;
    return roundPack(false, rootExponent - 1, sig);
}

unittest
{
    ulong r;
    assert(isqrt(0, r) == 0 && r == 0);
    assert(isqrt(1, r) == 1 && r == 0);
    assert(isqrt(15, r) == 3 && r == 6);
    assert(isqrt(16, r) == 4 && r == 0);
    assert(isqrt(ulong.max >> 2, r) == (1UL << 31) - 1);
    assert(isqrt(1UL << 62, r) == 1UL << 31 && r == 0);
}

unittest
{
    assert(sqrt(0x4000_0000) == 0x3fb5_04f3); // sqrt(2)
    assert(sqrt(0x4080_0000) == 0x4000_0000); // sqrt(4) = 2
    assert(sqrt(0x3f80_0000) == 0x3f80_0000);
    assert(sqrt(0x8000_0000) == 0x8000_0000);
    assert(sqrt(0) == 0);
    assert(sqrt(0xbf80_0000) == canonicalNaN);
    assert(sqrt(0xff80_0000) == canonicalNaN);
    assert(sqrt(0x7f80_0000) == 0x7f80_0000);
    assert(sqrt(0x7fc0_0000) == canonicalNaN);
    assert(sqrt(0x7f7f_ffff) == 0x5f7f_ffff); // sqrt(FLT_MAX)
    // sqrt(2^-149) = 2^-74.5: odd exponent, denormal input
    assert(sqrt(0x0000_0001) == 0x1a35_04f3);
    // sqrt(2^-126) = 2^-63
    assert(sqrt(0x0080_0000) == 0x2000_0000);
}
