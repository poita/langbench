/**
 * The shared round-and-pack step.
 *
 * Every operation in the library produces a truncated integer result and a
 * sticky bit.  They are all rounded here, exactly once, directly onto the
 * binary32 grid: normal, denormal, overflowing or underflowing.
 */
module softfloat.rounding;

import core.bitop : bsr;
import softfloat.bits;

@safe pure nothrow @nogc:

/**
 * Shifts `x` right by `count` bits, OR-ing every bit shifted out into the
 * least significant bit of the result ("jamming").  A nonzero `x` therefore
 * never becomes zero, and any inexactness stays visible as a sticky bit.
 * Counts of 64 or more collapse `x` to 0 or 1.
 */
ulong shiftRightJam(ulong x, uint count)
{
    if (count == 0)
        return x;
    if (count >= 64)
        return x != 0 ? 1 : 0;
    immutable lost = (x & ((1UL << count) - 1)) != 0;
    return (x >> count) | (lost ? 1 : 0);
}

/// Position of the leading one after normalisation inside `roundPack`.
private enum uint leadBit = 62;
/// Number of low bits dropped when rounding a 24-bit significand.
private enum uint dropBits = leadBit - fractionBits;

/**
 * Rounds `sig * 2^exp` to the nearest binary32 value (ties to even) and
 * returns its bit pattern.
 *
 * `sig` is an unsigned integer whose least significant bit may be a sticky
 * bit standing for "more nonzero bits were discarded below here".  For the
 * result to be correct the sticky bit must lie strictly below the rounding
 * position, which holds whenever `sig` has at least 26 significant bits
 * before any sticky bit is folded in (all callers provide 30 or more).
 *
 * Params:
 *   sign = sign of the result, also used for zero results
 *   exp  = power of two weighting bit 0 of `sig`
 *   sig  = significand with sticky bit; 0 yields a signed zero
 */
uint roundPack(bool sign, int exp, ulong sig)
{
    if (sig == 0)
        return zero(sign);

    // Normalise so the leading one sits at bit 62.
    immutable msb = bsr(sig);
    if (msb < leadBit)
        sig <<= leadBit - msb;
    else if (msb > leadBit)
        sig = shiftRightJam(sig, msb - leadBit);

    // Biased exponent of the leading one (1 means the smallest normal binade).
    int biased = exp + msb + 127;
    if (biased >= cast(int) maxExponentField)
        return infinity(sign);

    // In the denormal range the grid is coarser: shift further right.
    uint exponentFieldValue = 0;
    if (biased <= 0)
        sig = shiftRightJam(sig, cast(uint)(1 - biased));
    else
        exponentFieldValue = cast(uint)(biased - 1);

    uint quotient = cast(uint)(sig >> dropBits); // < 2^24
    immutable remainder = sig & ((1UL << dropBits) - 1);
    immutable half = 1UL << (dropBits - 1);
    if (remainder > half || (remainder == half && (quotient & 1)))
        ++quotient;

    // For normal results `quotient` carries the hidden bit, which bumps the
    // exponent field from `biased - 1` to `biased`.  A rounding carry out of
    // the significand, a denormal rounding up to 2^-126 and a round up to
    // infinity all fall out of the same addition.
    immutable bitsOut = (exponentFieldValue << fractionBits) + quotient;
    return (sign ? signMask : 0) | bitsOut;
}

unittest
{
    // shiftRightJam
    assert(shiftRightJam(0b1000, 3) == 1);
    assert(shiftRightJam(0b10010, 3) == 0b11);
    assert(shiftRightJam(5, 0) == 5);
    assert(shiftRightJam(5, 64) == 1);
    assert(shiftRightJam(0, 100) == 0);
}

unittest
{
    // 1.0 = 2^23 * 2^-23
    assert(roundPack(false, -23, 1UL << 23) == 0x3f80_0000);
    assert(roundPack(true, -23, 1UL << 23) == 0xbf80_0000);
    // zero keeps its sign
    assert(roundPack(true, 0, 0) == 0x8000_0000);
    // smallest denormal and smallest normal
    assert(roundPack(false, -149, 1) == 0x0000_0001);
    assert(roundPack(false, -149, 1UL << 23) == 0x0080_0000);
    // exactly half the smallest denormal: tie to even (0)
    assert(roundPack(false, -150, 1) == 0);
    // 1.5 * 2^-149: tie to even (2)
    assert(roundPack(false, -150, 3) == 2);
    // ... but a sticky bit breaks a tie upward: 2^-150 + 2^-180 -> 2^-149
    assert(roundPack(false, -180, (1UL << 30) | 1) == 1);
    // largest finite value, and the overflow threshold 2^128 - 2^103
    assert(roundPack(false, 104, 0xff_ffff) == 0x7f7f_ffff);
    assert(roundPack(false, 103, 0x1ff_fffe) == 0x7f7f_ffff); // 2^128 - 2^104
    assert(roundPack(false, 103, 0x1ff_ffff) == 0x7f80_0000); // exact tie -> inf
    assert(roundPack(false, 105, 0xff_ffff) == 0x7f80_0000);
    // a 1 + 2^-24 tie rounds down to 1, 1 + 3*2^-24 rounds up to 1 + 2^-22
    assert(roundPack(false, -24, (1UL << 24) | 1) == 0x3f80_0000);
    assert(roundPack(false, -24, (1UL << 24) | 3) == 0x3f80_0002);
    // rounding carry crosses into the next binade
    assert(roundPack(false, -24, 0x1ff_ffff) == 0x4000_0000);
}
