/**
 * Bit-level view of IEEE-754 binary32 values.
 *
 * Every value in this library is a raw `uint` bit pattern: 1 sign bit,
 * 8 exponent bits and 23 fraction bits.  Nothing in the library ever
 * converts to or from the language's `float` type.
 *
 * This module contains the field accessors, classification predicates and
 * the unpacking helper shared by the arithmetic modules.
 */
module softfloat.bits;

import core.bitop : bsr;

@safe pure nothrow @nogc:

/// Number of explicit fraction bits in a binary32 value.
enum uint fractionBits = 23;
/// Mask selecting the sign bit.
enum uint signMask = 0x8000_0000;
/// Mask selecting the 8-bit exponent field (in place).
enum uint exponentMask = 0x7f80_0000;
/// Mask selecting the 23-bit fraction field.
enum uint fractionMask = 0x007f_ffff;
/// The implicit leading bit of a normal significand.
enum uint hiddenBit = 0x0080_0000;
/// The exponent field value used by infinities and NaNs.
enum uint maxExponentField = 0xff;

/// The canonical quiet NaN, the only NaN this library ever returns.
enum uint canonicalNaN = 0x7fc0_0000;
/// Positive infinity.
enum uint positiveInfinity = 0x7f80_0000;
/// Positive zero.
enum uint positiveZero = 0;

/// Sign bit of `x` (`true` when negative, including `-0` and negative NaNs).
bool signOf(uint x)
{
    return (x >> 31) != 0;
}

/// The biased exponent field of `x` (0 to 255).
uint exponentField(uint x)
{
    return (x >> fractionBits) & maxExponentField;
}

/// The 23-bit fraction field of `x`.
uint fractionField(uint x)
{
    return x & fractionMask;
}

/// `x` with its sign bit flipped.
uint negate(uint x)
{
    return x ^ signMask;
}

/// `true` if `x` is a NaN of any sign, payload or quietness.
bool isNaN(uint x)
{
    return (x & ~signMask) > exponentMask;
}

/// `true` if `x` is +infinity or -infinity.
bool isInfinity(uint x)
{
    return (x & ~signMask) == exponentMask;
}

/// `true` if `x` is +0 or -0.
bool isZero(uint x)
{
    return (x & ~signMask) == 0;
}

/// Assembles a bit pattern from a sign, biased exponent field and fraction.
/// No range checking: the fields are masked into place.
uint pack(bool sign, uint exponent, uint fraction)
{
    return (sign ? signMask : 0)
        | ((exponent & maxExponentField) << fractionBits)
        | (fraction & fractionMask);
}

/// Infinity with the given sign.
uint infinity(bool sign)
{
    return pack(sign, maxExponentField, 0);
}

/// Zero with the given sign.
uint zero(bool sign)
{
    return pack(sign, 0, 0);
}

/**
 * A finite, nonzero operand as an integer significand and exponent:
 * its magnitude is exactly `significand * 2^exponent`.
 */
struct Unpacked
{
    /// Sign of the value.
    bool sign;
    /// Integer significand; below 2^24.
    uint significand;
    /// Power of two weighting the significand's least significant bit.
    int exponent;
}

/**
 * Unpacks a finite `x` (zero is allowed; infinities and NaNs are not).
 *
 * Normal numbers get `significand = 2^23 | fraction` and
 * `exponent = field - 150`.  Denormals keep their raw fraction and use the
 * exponent of the smallest normal binade, `-149`, so the value formula is
 * the same for both.
 */
Unpacked unpack(uint x)
in (!isNaN(x) && !isInfinity(x))
{
    immutable field = exponentField(x);
    immutable frac = fractionField(x);
    if (field == 0)
        return Unpacked(signOf(x), frac, -149);
    return Unpacked(signOf(x), frac | hiddenBit, cast(int) field - 150);
}

/**
 * Like $(LREF unpack), but shifts a nonzero significand left until bit 23 is
 * set (lowering the exponent to compensate), so denormals are normalised.
 * The significand of a zero operand stays 0.
 */
Unpacked unpackNormalized(uint x)
{
    auto u = unpack(x);
    if (u.significand != 0 && u.significand < hiddenBit)
    {
        immutable shift = 23 - bsr(u.significand);
        u.significand <<= shift;
        u.exponent -= shift;
    }
    return u;
}

unittest
{
    assert(signOf(0x8000_0000) && !signOf(0x7fff_ffff));
    assert(exponentField(0x3f80_0000) == 127);
    assert(fractionField(0x3f80_0001) == 1);
    assert(isNaN(0x7fc0_0000) && isNaN(0xff80_0001) && isNaN(0x7f80_0001));
    assert(!isNaN(0x7f80_0000) && !isNaN(0xff80_0000) && !isNaN(0x7f7f_ffff));
    assert(isInfinity(0x7f80_0000) && isInfinity(0xff80_0000));
    assert(isZero(0) && isZero(0x8000_0000) && !isZero(1));
    assert(pack(true, 127, 0) == 0xbf80_0000);
    assert(infinity(true) == 0xff80_0000);
    assert(zero(true) == 0x8000_0000);
    assert(negate(0x3f80_0000) == 0xbf80_0000);
}

unittest
{
    // 1.0 = 2^23 * 2^-23
    auto one = unpack(0x3f80_0000);
    assert(!one.sign && one.significand == 0x80_0000 && one.exponent == -23);
    // smallest denormal = 1 * 2^-149
    auto tiny = unpack(0x8000_0001);
    assert(tiny.sign && tiny.significand == 1 && tiny.exponent == -149);
    auto n = unpackNormalized(0x0000_0001);
    assert(n.significand == 0x80_0000 && n.exponent == -149 - 23);
    // normalising does not change the value of a normal number
    assert(unpackNormalized(0x3f80_0000) == unpack(0x3f80_0000));
}
