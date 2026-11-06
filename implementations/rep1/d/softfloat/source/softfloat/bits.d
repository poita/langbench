/**
 * Bit-level definitions for IEEE-754 binary32 values.
 *
 * All values are handled as raw `uint` bit patterns. Nothing in this module
 * (or the rest of the library) uses floating-point arithmetic.
 */
module softfloat.bits;

import core.bitop : bsr;

@safe pure nothrow @nogc:

/// Sign bit of a binary32 pattern.
enum uint signMask = 0x8000_0000;
/// Exponent field mask.
enum uint expMask = 0x7f80_0000;
/// Fraction field mask.
enum uint fracMask = 0x007f_ffff;
/// The implicit leading significand bit of normal numbers.
enum uint hiddenBit = 0x0080_0000;
/// The only NaN pattern the library ever produces.
enum uint canonicalNaN = 0x7fc0_0000;
/// Positive infinity.
enum uint positiveInfinity = 0x7f80_0000;
/// Exponent of the least significant bit of a denormal (value = m * 2^-149).
enum int minExponent = -149;

/// True if `x` is a NaN (any sign, quiet or signaling, any payload).
bool isNaN(uint x)
{
    return (x & expMask) == expMask && (x & fracMask) != 0;
}

/// True if `x` is +infinity or -infinity.
bool isInfinity(uint x)
{
    return (x & ~signMask) == expMask;
}

/// True if `x` is +0 or -0.
bool isZero(uint x)
{
    return (x & ~signMask) == 0;
}

/// A finite, nonzero operand as `mantissa * 2^exponent`.
struct Unpacked
{
    ulong mantissa; /// Integer significand (24 bits for normals, fewer for denormals).
    int exponent;   /// Power of two applied to `mantissa`.
}

/**
 * Unpacks a finite nonzero pattern onto the 2^-149 grid.
 *
 * Normals give `m = frac | 2^23`, `e = biased - 150`; denormals give
 * `m = frac`, `e = -149`. The sign is ignored.
 */
Unpacked unpack(uint x)
{
    immutable biased = (x & expMask) >> 23;
    immutable frac = x & fracMask;
    if (biased == 0)
        return Unpacked(frac, minExponent);
    return Unpacked(frac | hiddenBit, cast(int) biased - 150);
}

/// Like `unpack`, but shifts the significand so that bit 23 is set.
Unpacked unpackNormalized(uint x)
{
    auto u = unpack(x);
    immutable lz = 23 - bsr(cast(uint) u.mantissa);
    u.mantissa <<= lz;
    u.exponent -= lz;
    return u;
}
