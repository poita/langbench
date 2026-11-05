/// Exact integer arithmetic used throughout the engine: floor division,
/// glyph-space scaling, numeral formatting and the line-badness formula.
module typeset.arith;

import core.int128 : Cent, mul, udivmod;

/// Floor division `a div b` for `b > 0`.
long fdiv(long a, long b) pure nothrow @nogc @safe
{
    long q = a / b;
    if (a % b != 0 && a < 0)
        --q;
    return q;
}

/// Scales a glyph-space quantity `u` (thousandths of an em) to millipoints at
/// size `s`: `(u * s) div 1000`.
long scale(long u, long s) pure nothrow @nogc @safe
{
    return fdiv(u * s, 1000);
}

/// Lowercase roman numeral by greedy subtraction; works above 3999 too.
string toRoman(long n) pure @safe
{
    static immutable long[13] vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    static immutable string[13] syms = ["m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i"];
    string r;
    foreach (i, v; vals)
        while (n >= v)
        {
            r ~= syms[i];
            n -= v;
        }
    return r;
}

/// Bijective base-26 lowercase letters: 1 -> a, 26 -> z, 27 -> aa.
string toLetters(long n) pure @safe
{
    char[] r;
    while (n > 0)
    {
        --n;
        r = cast(char)('a' + n % 26) ~ r;
        n /= 26;
    }
    return r.idup;
}

/// Decimal text of an integer.
string toDecimal(long n) pure @safe
{
    char[24] buf;
    size_t p = buf.length;
    bool neg = n < 0;
    ulong u = neg ? cast(ulong)(-(n + 1)) + 1 : cast(ulong) n;
    do
    {
        buf[--p] = cast(char)('0' + u % 10);
        u /= 10;
    }
    while (u != 0);
    if (neg)
        buf[--p] = '-';
    return buf[p .. $].idup;
}

/// Fitness classes of a line.
enum Fitness : ubyte
{
    tight = 0,
    decent = 1,
    loose = 2,
    veryLoose = 3,
}

/// Feasibility category of a line against its measure.
enum LineKind : ubyte
{
    normal,
    unstretchable,
    overfull,
}

/// Result of measuring a line's natural width against its measure.
struct LineFit
{
    int badness;
    Fitness fitness;
    LineKind kind;
}

/// `min(10000, (100 * d^3) div y^3)` computed exactly, for `d >= 0`, `y > 0`.
int cubicBadness(long d, long y) nothrow @nogc @trusted
{
    if (d >= 5 * y)
        return 10000;
    if (d == 0)
        return 0;
    // Fast path: 100 * d^3 and y^3 both fit in an unsigned 64-bit integer.
    if (d <= 560_000 && y <= 2_000_000)
    {
        ulong d3 = cast(ulong) d * d * d;
        ulong y3 = cast(ulong) y * y * y;
        ulong q = (100 * d3) / y3;
        return q > 10000 ? 10000 : cast(int) q;
    }
    // Slow path: 128-bit intermediates (d < 5y keeps both below 2^40 in practice).
    if (d > (1L << 40))
        return 10000;
    Cent d3 = mul(mul(Cent(d, 0), Cent(d, 0)), Cent(d, 0));
    Cent n = mul(d3, Cent(100, 0));
    Cent den = mul(mul(Cent(y, 0), Cent(y, 0)), Cent(y, 0));
    Cent rem;
    Cent quo = udivmod(n, den, rem);
    if (quo.hi != 0 || quo.lo > 10000)
        return 10000;
    return cast(int) quo.lo;
}

/// Evaluates a line of natural width `w`, stretch `y`, shrink `z` (and whether
/// it contains the infinite glue) against measure `len`.
LineFit evaluateLine(long w, long y, long z, bool infinite, long len) nothrow @nogc @safe
{
    immutable long d = len - w;
    if (d >= 0 && infinite)
        return LineFit(0, Fitness.decent, LineKind.normal);
    if (d == 0)
        return LineFit(0, Fitness.decent, LineKind.normal);
    if (d > 0)
    {
        if (y == 0)
            return LineFit(10000, Fitness.veryLoose, LineKind.unstretchable);
        immutable int b = cubicBadness(d, y);
        Fitness f = d > y ? Fitness.veryLoose : (2 * d > y ? Fitness.loose : Fitness.decent);
        return LineFit(b, f, LineKind.normal);
    }
    immutable long e = -d;
    if (z == 0 || e > z)
        return LineFit(10000, Fitness.tight, LineKind.overfull);
    immutable int b = cubicBadness(e, z);
    return LineFit(b, 2 * e > z ? Fitness.tight : Fitness.decent, LineKind.normal);
}

/// Number of Unicode scalar values in a UTF-8 slice (counts non-continuation bytes).
size_t codepointCount(const(char)[] s) pure nothrow @nogc @safe
{
    size_t n;
    foreach (c; s)
        if ((c & 0xC0) != 0x80)
            ++n;
    return n;
}
