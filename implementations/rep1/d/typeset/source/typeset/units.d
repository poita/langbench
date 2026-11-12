/**
 * Integer arithmetic helpers shared by the whole engine.
 *
 * Every quantity in the Codexa engine is an integer. Lengths are measured in
 * millipoints, and division is always floor division, which differs from D's
 * truncating `/` for negative operands.
 */
module typeset.units;

import std.conv : to;

/// One typographic point in millipoints.
enum long pt = 1000;

/// Floor division: the unique `q` with `a == q*b + r` and `0 <= r < b` (`b > 0`).
long fdiv(long a, long b) pure nothrow @safe @nogc
in (b > 0)
{
    long q = a / b;
    if (a % b != 0 && a < 0)
        --q;
    return q;
}

///
@safe pure nothrow @nogc unittest
{
    assert(fdiv(7, 2) == 3);
    assert(fdiv(-7, 2) == -4);
    assert(fdiv(-3307000, 5100) == -649);
    assert(fdiv(-4, 2) == -2);
    assert(fdiv(0, 5) == 0);
}

/// Scales a glyph-space quantity `u` (1/1000 em) to millipoints at size `s`.
long scale(long u, long s) pure nothrow @safe @nogc
{
    return fdiv(u * s, 1000);
}

@safe pure nothrow @nogc unittest
{
    assert(scale(1563, 10_000) == 15_630);
    assert(scale(1054, 11_000) == 11_594);
    assert(scale(-60, 10_000) == -600);
    assert(scale(-1, 1) == -1); // floors towards negative infinity
}

/// Lowercase roman numeral by greedy subtraction; works above 3999 too.
string roman(long n) pure @safe
{
    static immutable long[13] values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    static immutable string[13] symbols = ["m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i"];
    string result;
    foreach (i, v; values)
    {
        while (n >= v)
        {
            result ~= symbols[i];
            n -= v;
        }
    }
    return result;
}

@safe pure unittest
{
    assert(roman(1) == "i");
    assert(roman(4) == "iv");
    assert(roman(14) == "xiv");
    assert(roman(2026) == "mmxxvi");
    assert(roman(4000) == "mmmm");
    assert(roman(5001) == "mmmmmi");
}

/// Bijective base-26 lowercase letters: 1 is `a`, 26 is `z`, 27 is `aa`.
string letters(long n) pure @safe
{
    char[] reversed;
    while (n > 0)
    {
        --n;
        reversed ~= cast(char)('a' + n % 26);
        n /= 26;
    }
    char[] result;
    foreach_reverse (c; reversed)
        result ~= c;
    return result.idup;
}

@safe pure unittest
{
    assert(letters(1) == "a");
    assert(letters(26) == "z");
    assert(letters(27) == "aa");
    assert(letters(28) == "ab");
    assert(letters(52) == "az");
    assert(letters(53) == "ba");
}

/// Computes `(100 * d^3) div y^3` exactly, clamped to at most `cap`.
///
/// `100 * d^3` can exceed 64 bits, so the slow path uses 128-bit arithmetic.
long cubeRatio100(long d, long y, long cap) pure nothrow @safe @nogc
in (d >= 0 && y > 0)
{
    // d^3 >= 100 y^3 certainly when d >= 5y, and the result is then >= 12500.
    if (d / 5 >= y)
        return cap;
    enum long fastD = 400_000, fastY = 2_000_000;
    if (d <= fastD && y <= fastY)
    {
        immutable r = (100 * d * d * d) / (y * y * y);
        return r < cap ? r : cap;
    }
    import core.int128 : Cent, mul, udivmod;

    // Slow path: 128-bit numerator and denominator (d <= 5y, y < 2^40).
    Cent dd = Cent(d, 0);
    Cent yy = Cent(y, 0);
    Cent num = mul(mul(dd, mul(dd, dd)), Cent(100, 0));
    Cent den = mul(yy, mul(yy, yy));
    Cent rem;
    Cent q = udivmod(num, den, rem);
    if (q.hi != 0 || q.lo > cast(ulong) cap)
        return cap;
    return cast(long) q.lo;
}

@safe pure nothrow @nogc unittest
{
    assert(cubeRatio100(11_020, 6_350, 10_000) == 522);
    assert(cubeRatio100(3_890, 5_100, 10_000) == 44);
    assert(cubeRatio100(30_950, 5_080, 10_000) == 10_000);
    assert(cubeRatio100(3_110, 3_400, 10_000) == 76);
    assert(cubeRatio100(0, 1, 10_000) == 0);
}
