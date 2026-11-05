/**
 * Exact decimal numbers.
 *
 * A JSON number literal denotes the rational `mantissa * 10^exponent`. This
 * module keeps numbers in that form (never as binary floating point), so
 * comparison, integer tests and `multipleOf` are exact.
 */
module jsonschema.number;

import core.checkedint : muls;
import std.bigint : BigInt;

/// Scratch buffer used while parsing literals (thread-local).
private char[] scratch;

private immutable long[19] powersOfTen = () {
    long[19] t;
    long p = 1;
    foreach (i; 0 .. 19)
    {
        t[i] = p;
        if (i < 18)
            p *= 10;
    }
    return t;
}();

private BigInt pow10Big(int n)
{
    return BigInt(10) ^^ n;
}

private BigInt absBig(BigInt b)
{
    return b < 0 ? -b : b;
}

/**
 * An exact decimal number in canonical form.
 *
 * The mantissa has no trailing zeros (they are folded into the exponent);
 * zero is mantissa 0, exponent 0. Because the form is canonical, two numbers
 * are equal exactly when their fields are equal.
 */
struct Number
{
    /// Mantissa when it fits in 18 digits; otherwise only its sign (±1).
    long m;
    /// Decimal exponent: value = mantissa * 10^e.
    int e;
    /// Number of decimal digits in the mantissa (1 for zero).
    int digits = 1;
    /// The mantissa when it does not fit a machine integer, else null.
    BigInt* big;

    /// Parses a JSON number literal (`-12.5e3`). The literal must be well formed.
    static Number fromLiteral(const(char)[] s)
    {
        size_t i = 0;
        bool neg = false;
        if (i < s.length && s[i] == '-')
        {
            neg = true;
            i++;
        }
        auto buf = scratch;
        buf.length = 0;
        buf.assumeSafeAppend();
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
            buf ~= s[i++];
        long frac = 0;
        if (i < s.length && s[i] == '.')
        {
            i++;
            while (i < s.length && s[i] >= '0' && s[i] <= '9')
            {
                buf ~= s[i++];
                frac++;
            }
        }
        long ex = 0;
        if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
        {
            i++;
            bool eneg = false;
            if (i < s.length && (s[i] == '+' || s[i] == '-'))
            {
                eneg = s[i] == '-';
                i++;
            }
            while (i < s.length && s[i] >= '0' && s[i] <= '9')
            {
                if (ex < 1_000_000_000)
                    ex = ex * 10 + (s[i] - '0');
                i++;
            }
            if (eneg)
                ex = -ex;
        }
        auto r = fromDigits(neg, buf, ex - frac);
        scratch = buf;
        return r;
    }

    /// Builds a number from decimal digits (no sign, no point) and an exponent.
    static Number fromDigits(bool negative, const(char)[] ds, long exponent)
    {
        size_t a = 0, b = ds.length;
        while (a < b && ds[a] == '0')
            a++;
        while (b > a && ds[b - 1] == '0')
        {
            b--;
            exponent++;
        }
        Number r;
        if (a == b)
            return r;
        if (exponent > int.max / 2)
            exponent = int.max / 2;
        if (exponent < -(int.max / 2))
            exponent = -(int.max / 2);
        r.e = cast(int) exponent;
        r.digits = cast(int)(b - a);
        if (r.digits <= 18)
        {
            long v = 0;
            foreach (c; ds[a .. b])
                v = v * 10 + (c - '0');
            r.m = negative ? -v : v;
        }
        else
        {
            auto bi = BigInt(ds[a .. b].idup);
            if (negative)
                bi = -bi;
            r.big = new BigInt(bi);
            r.m = negative ? -1 : 1;
        }
        return r;
    }

    /// Builds a number from a machine integer.
    static Number fromLong(long v)
    {
        import std.conv : to;

        if (v == long.min)
            return fromDigits(true, "9223372036854775808", 0);
        return fromDigits(v < 0, (v < 0 ? -v : v).to!string, 0);
    }

    /// -1, 0 or 1.
    int sign() const
    {
        return m > 0 ? 1 : (m < 0 ? -1 : 0);
    }

    /// True when the number denotes a whole number (`1.0`, `1e2` and `-0` are integers).
    bool isInteger() const
    {
        return e >= 0;
    }

    /// The mantissa as an arbitrary-precision integer.
    BigInt mantissa() const
    {
        return big ? cast(BigInt)(*big) : BigInt(m);
    }

    /**
     * Converts to a count: the value truncated to an integer, clamped to
     * `[-1, long.max]` (negative values give -1, huge values saturate).
     */
    long toCount() const
    {
        if (sign < 0)
            return -1;
        if (sign == 0)
            return 0;
        if (e >= 0)
        {
            if (big !is null || e + digits > 18)
                return long.max;
            return m * powersOfTen[e];
        }
        immutable k = -e;
        if (k >= digits)
            return 0;
        if (big !is null)
            return long.max;
        return m / powersOfTen[k];
    }

    /// Equality of the denoted values.
    bool opEquals(const Number o) const
    {
        if (e != o.e || digits != o.digits)
            return false;
        if (big is null && o.big is null)
            return m == o.m;
        if (big !is null && o.big !is null)
            return cast(BigInt)(*big) == cast(BigInt)(*o.big);
        return false;
    }

    /// Ordering of the denoted values.
    int opCmp(const Number o) const
    {
        return compare(this, o);
    }

    /// Hash consistent with `opEquals`.
    size_t toHash() const nothrow
    {
        size_t h = cast(size_t) m * 0x9E3779B97F4A7C15UL;
        h ^= cast(size_t) e * 31 + cast(size_t) digits;
        if (big !is null)
        {
            try
                h ^= big.toHash();
            catch (Exception)
            {
            }
        }
        return h;
    }

    /// Renders the number as `<mantissa>` or `<mantissa>e<exponent>`.
    string toString() const
    {
        import std.conv : to;

        string ms = big ? (cast(BigInt)(*big)).to!string : m.to!string;
        return e == 0 ? ms : ms ~ "e" ~ e.to!string;
    }
}

private int cmpAbs(const Number a, const Number b)
{
    immutable ta = a.digits + a.e, tb = b.digits + b.e;
    if (ta != tb)
        return ta < tb ? -1 : 1;
    if (a.big is null && b.big is null && a.e == b.e)
    {
        immutable x = a.m < 0 ? -a.m : a.m;
        immutable y = b.m < 0 ? -b.m : b.m;
        return x < y ? -1 : (x > y ? 1 : 0);
    }
    BigInt x = absBig(a.mantissa), y = absBig(b.mantissa);
    if (a.e > b.e)
        x *= pow10Big(a.e - b.e);
    else if (b.e > a.e)
        y *= pow10Big(b.e - a.e);
    return x < y ? -1 : (x > y ? 1 : 0);
}

/// Exact three-way comparison.
int compare(const Number a, const Number b)
{
    immutable sa = a.sign, sb = b.sign;
    if (sa != sb)
        return sa < sb ? -1 : 1;
    if (sa == 0)
        return 0;
    immutable c = cmpAbs(a, b);
    return sa > 0 ? c : -c;
}

/// True when `x / d` is an integer, computed exactly. `d` must be positive.
bool isMultipleOf(const Number x, const Number d)
{
    if (x.sign == 0)
        return true;
    if (d.sign == 0)
        return false;
    immutable diff = x.e - d.e;
    if (x.big is null && d.big is null)
    {
        immutable long a = x.m < 0 ? -x.m : x.m;
        immutable long b = d.m < 0 ? -d.m : d.m;
        if (diff >= 0)
        {
            if (diff <= 18)
            {
                bool ov;
                immutable prod = muls(a, powersOfTen[diff], ov);
                if (!ov)
                    return prod % b == 0;
            }
        }
        else
        {
            immutable k = -diff;
            if (k > 18)
                return false;
            bool ov;
            immutable q = muls(b, powersOfTen[k], ov);
            if (ov)
                return false;
            return a % q == 0;
        }
    }
    BigInt a = absBig(x.mantissa), b = absBig(d.mantissa);
    if (diff >= 0)
        return (a * pow10Big(diff)) % b == 0;
    return a % (b * pow10Big(-diff)) == 0;
}
