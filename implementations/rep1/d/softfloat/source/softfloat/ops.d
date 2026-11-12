/**
 * A small value type wrapping a raw binary32 bit pattern, with operator
 * overloads that dispatch to the integer-only implementations.
 */
module softfloat.ops;

import softfloat.addsub;
import softfloat.bits;
import softfloat.div;
import softfloat.mul;
import softfloat.sqrt;

@safe pure nothrow @nogc:

/**
 * An IEEE-754 binary32 value stored as its raw bits.
 *
 * Arithmetic operators round to nearest-even, support denormals, and follow
 * the NaN, infinity and signed-zero rules of the specification.  Any NaN
 * result is the canonical quiet NaN `0x7fc00000`.
 */
struct Float32
{
@safe pure nothrow @nogc:

    /// The raw IEEE-754 bit pattern.
    uint bits;

    /// Builds a value from its raw bit pattern.
    static Float32 fromBits(uint bits)
    {
        return Float32(bits);
    }

    /// `+`, `-`, `*` and `/` on two values.
    Float32 opBinary(string op)(const Float32 rhs) const
        if (op == "+" || op == "-" || op == "*" || op == "/")
    {
        static if (op == "+")
            return Float32(softfloat.addsub.add(bits, rhs.bits));
        else static if (op == "-")
            return Float32(softfloat.addsub.sub(bits, rhs.bits));
        else static if (op == "*")
            return Float32(softfloat.mul.mul(bits, rhs.bits));
        else
            return Float32(softfloat.div.div(bits, rhs.bits));
    }

    /// Unary minus flips the sign bit (also for NaNs, as in hardware).
    Float32 opUnary(string op : "-")() const
    {
        return Float32(negate(bits));
    }

    /// Square root of this value.
    Float32 sqrt() const
    {
        return Float32(softfloat.sqrt.sqrt(bits));
    }

    /// `true` if this value is a NaN.
    bool isNaN() const
    {
        return softfloat.bits.isNaN(bits);
    }

    /// `true` if this value is an infinity.
    bool isInfinity() const
    {
        return softfloat.bits.isInfinity(bits);
    }

    /// `true` if this value is a zero of either sign.
    bool isZero() const
    {
        return softfloat.bits.isZero(bits);
    }
}

///
unittest
{
    immutable one = Float32(0x3f80_0000);
    immutable three = Float32(0x4040_0000);
    assert((one / three).bits == 0x3eaa_aaab);
    assert((one + one).bits == 0x4000_0000);
    assert((one - one).bits == 0);
    assert((-three * three).bits == 0xc110_0000);
    assert(Float32(0x4000_0000).sqrt.bits == 0x3fb5_04f3);
    assert((Float32(0x7f80_0000) - Float32(0x7f80_0000)).isNaN);
}
