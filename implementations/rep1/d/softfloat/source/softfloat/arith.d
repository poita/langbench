/**
 * IEEE-754 binary32 arithmetic on raw bit patterns.
 *
 * Every function takes and returns `uint` bit patterns, rounds to nearest
 * (ties to even) with full gradual underflow, and returns the canonical quiet
 * NaN (`0x7fc00000`) for NaN operands and invalid operations. Only integer
 * operations on at most 64-bit words are used.
 */
module softfloat.arith;

import core.bitop : bsr;
import softfloat.bits;
import softfloat.round;

@safe pure nothrow @nogc:

/// Guard bits used to align operands in `add`.
private enum int guardBits = 35;

/// Returns `a + b`.
uint add(uint a, uint b)
{
    if (isNaN(a) || isNaN(b))
        return canonicalNaN;
    immutable bool sa = (a & signMask) != 0;
    immutable bool sb = (b & signMask) != 0;

    if (isInfinity(a))
    {
        if (isInfinity(b) && sa != sb)
            return canonicalNaN;
        return a;
    }
    if (isInfinity(b))
        return b;

    if (isZero(a))
    {
        if (isZero(b))
            return (sa && sb) ? signMask : 0;
        return b;
    }
    if (isZero(b))
        return a;

    auto ua = unpack(a);
    auto ub = unpack(b);
    // Order by magnitude so the larger operand comes first.
    immutable swap = ua.exponent < ub.exponent
        || (ua.exponent == ub.exponent && ua.mantissa < ub.mantissa);
    if (swap)
        return addOrdered(sb, ub, ua, sa != sb);
    return addOrdered(sa, ua, ub, sa != sb);
}

private uint addOrdered(bool negative, Unpacked big, Unpacked small, bool subtract)
{
    immutable int d = big.exponent - small.exponent;
    immutable ulong A = big.mantissa << guardBits;
    immutable ulong full = small.mantissa << guardBits;
    ulong B;
    bool sticky;
    if (d >= 64)
    {
        B = 0;
        sticky = true;
    }
    else
    {
        B = full >> d;
        sticky = (full & ((1UL << d) - 1)) != 0;
    }

    ulong r;
    if (subtract)
    {
        r = A - B - (sticky ? 1 : 0);
        if (r == 0 && !sticky)
            return 0; // exact cancellation gives +0
    }
    else
    {
        r = A + B;
    }
    return roundPack(negative, r, big.exponent - guardBits, sticky);
}

/// Returns `a - b`.
uint sub(uint a, uint b)
{
    return add(a, b ^ signMask);
}

/// Returns `a * b`.
uint mul(uint a, uint b)
{
    if (isNaN(a) || isNaN(b))
        return canonicalNaN;
    immutable bool neg = ((a ^ b) & signMask) != 0;
    immutable uint sign = neg ? signMask : 0;

    if (isInfinity(a) || isInfinity(b))
    {
        if (isZero(a) || isZero(b))
            return canonicalNaN;
        return sign | positiveInfinity;
    }
    if (isZero(a) || isZero(b))
        return sign;

    immutable ua = unpack(a);
    immutable ub = unpack(b);
    return roundPack(neg, ua.mantissa * ub.mantissa, ua.exponent + ub.exponent, false);
}

/// Returns `a / b`.
uint div(uint a, uint b)
{
    if (isNaN(a) || isNaN(b))
        return canonicalNaN;
    immutable bool neg = ((a ^ b) & signMask) != 0;
    immutable uint sign = neg ? signMask : 0;

    if (isInfinity(a))
        return isInfinity(b) ? canonicalNaN : (sign | positiveInfinity);
    if (isInfinity(b))
        return sign;
    if (isZero(b))
        return isZero(a) ? canonicalNaN : (sign | positiveInfinity);
    if (isZero(a))
        return sign;

    immutable ua = unpackNormalized(a);
    immutable ub = unpackNormalized(b);
    enum int k = 32;
    immutable ulong num = ua.mantissa << k;
    immutable ulong q = num / ub.mantissa;
    immutable ulong r = num % ub.mantissa;
    return roundPack(neg, q, ua.exponent - ub.exponent - k, r != 0);
}

/// Returns the square root of `a`.
uint sqrt(uint a)
{
    if (isNaN(a))
        return canonicalNaN;
    if (isZero(a))
        return a;
    if (a & signMask)
        return canonicalNaN;
    if (isInfinity(a))
        return a;

    auto u = unpackNormalized(a);
    if (u.exponent & 1)
    {
        u.mantissa <<= 1;
        --u.exponent;
    }
    enum int scale = 36; // even
    ulong n = u.mantissa << scale;

    // Classic restoring digit-by-digit integer square root.
    ulong root = 0;
    ulong bit = 1UL << (bsr(n) & ~1);
    while (bit != 0)
    {
        if (n >= root + bit)
        {
            n -= root + bit;
            root = (root >> 1) + bit;
        }
        else
        {
            root >>= 1;
        }
        bit >>= 2;
    }
    return roundPack(false, root, (u.exponent - scale) / 2, n != 0);
}
