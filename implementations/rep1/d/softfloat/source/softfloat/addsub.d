/**
 * Addition and subtraction.
 *
 * The operand with the smaller magnitude is aligned to the larger one with a
 * fixed number of guard bits; bits shifted out beyond them are folded into a
 * sticky bit.  The aligned significands are then added or subtracted as plain
 * 64-bit integers and handed to $(REF roundPack, softfloat,rounding).
 */
module softfloat.addsub;

import softfloat.bits;
import softfloat.rounding;

@safe pure nothrow @nogc:

/// Guard bits appended below the 24-bit significands before alignment.
private enum uint guardBits = 32;

/// Returns the bit pattern of `a + b`, rounded to nearest-even.
uint add(uint a, uint b)
{
    if (isNaN(a) || isNaN(b))
        return canonicalNaN;

    if (isInfinity(a) || isInfinity(b))
    {
        // inf + (-inf) is invalid; otherwise the infinity wins.
        if (isInfinity(a) && isInfinity(b))
            return signOf(a) == signOf(b) ? a : canonicalNaN;
        return isInfinity(a) ? a : b;
    }

    if (isZero(a) || isZero(b))
    {
        if (isZero(a) && isZero(b))
            return zero(signOf(a) && signOf(b)); // -0 + -0 = -0, else +0
        return isZero(a) ? b : a;
    }

    // Order by magnitude so `big` is the larger operand.
    immutable aIsBig = (a & ~signMask) >= (b & ~signMask);
    immutable big = unpack(aIsBig ? a : b);
    immutable small = unpack(aIsBig ? b : a);

    // Align `small` to `big`'s exponent, keeping everything in 64 bits.
    immutable ulong bigSig = cast(ulong) big.significand << guardBits;
    immutable ulong smallSig = shiftRightJam(
        cast(ulong) small.significand << guardBits,
        cast(uint)(big.exponent - small.exponent));

    immutable subtract = big.sign != small.sign;
    immutable ulong sum = subtract ? bigSig - smallSig : bigSig + smallSig;
    if (sum == 0)
        return positiveZero; // exact cancellation of nonzero values
    return roundPack(big.sign, big.exponent - cast(int) guardBits, sum);
}

/// Returns the bit pattern of `a - b`; identical to `add(a, negate(b))`.
uint sub(uint a, uint b)
{
    return add(a, negate(b));
}

unittest
{
    assert(add(0x3f80_0000, 0x3f80_0000) == 0x4000_0000); // 1 + 1
    assert(sub(0x3f80_0000, 0x3f80_0000) == 0);           // 1 - 1
    assert(add(0x7f80_0000, 0xff80_0000) == canonicalNaN);
    assert(add(0x7fc1_2345, 0x3f80_0000) == canonicalNaN);
    assert(add(0x8000_0000, 0x8000_0000) == 0x8000_0000);
    assert(add(0x8000_0000, 0x0000_0000) == 0);
    assert(sub(0x8000_0000, 0x0000_0000) == 0x8000_0000);
    assert(sub(0x8000_0000, 0x8000_0000) == 0);
    assert(add(0x8000_0000, 0x3f80_0000) == 0x3f80_0000);
    assert(add(0x7f80_0000, 0x3f80_0000) == 0x7f80_0000);
    assert(add(0xff80_0000, 0xff80_0000) == 0xff80_0000);
}

unittest
{
    // Rounding at the edges (SPEC.md, example 3).
    assert(add(0x7f7f_ffff, 0x7300_0000) == 0x7f80_0000);
    assert(add(0x7f7f_ffff, 0x72ff_ffff) == 0x7f7f_ffff);
    assert(add(0x3f80_0000, 0x3380_0000) == 0x3f80_0000);
    assert(add(0x3f80_0001, 0x3380_0000) == 0x3f80_0002);
    assert(add(0x3f80_0000, 0x3300_0000) == 0x3f80_0000);
    // Denormal arithmetic is exact, and carries into the smallest normal.
    assert(add(0x0000_0001, 0x0000_0001) == 0x0000_0002);
    assert(add(0x007f_ffff, 0x0000_0001) == 0x0080_0000);
    assert(sub(0x0080_0000, 0x0000_0001) == 0x007f_ffff);
    // Massive cancellation is exact.
    assert(sub(0x3f80_0001, 0x3f80_0000) == 0x3400_0000);
}
