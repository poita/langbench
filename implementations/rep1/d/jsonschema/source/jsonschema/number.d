/**
 * Exact decimal numbers.
 *
 * JSON Schema compares and divides numbers exactly, so a number is kept as the
 * rational `mantissa * 10^exponent`, with an arbitrary-precision mantissa.
 * Values are stored in a canonical form (the mantissa has no trailing decimal
 * zeros, and zero is `0 * 10^0`), which makes equality and hashing structural.
 */
module jsonschema.number;

import std.bigint : BigInt;

/// An exact decimal number `mantissa * 10 ^^ exponent`.
struct Number
{
    /// Canonical mantissa (no trailing decimal zeros; zero for the value 0).
    BigInt mantissa;
    /// Canonical decimal exponent (0 when the value is zero).
    int exponent;

    /// Builds a number from a sign, a digit string and an exponent.
    /// `digits` holds the decimal digits with the point removed.
    static Number fromDigits(bool negative, const(char)[] digits, long exponent)
    {
        size_t end = digits.length;
        size_t start = 0;
        while (start < end && digits[start] == '0')
            start++;
        while (end > start && digits[end - 1] == '0')
        {
            end--;
            exponent++;
        }
        Number n;
        if (start == end)
            return n; // zero
        auto body_ = digits[start .. end];
        if (body_.length <= 18)
        {
            long v = 0;
            foreach (c; body_)
                v = v * 10 + (c - '0');
            n.mantissa = BigInt(negative ? -v : v);
        }
        else
        {
            n.mantissa = BigInt(body_.idup);
            if (negative)
                n.mantissa = -n.mantissa;
        }
        n.exponent = cast(int) exponent;
        return n;
    }

    /// Builds a number from a machine integer.
    static Number fromLong(long v)
    {
        Number n;
        if (v == 0)
            return n;
        n.mantissa = BigInt(v);
        n.exponent = 0;
        while (n.mantissa % 10 == 0)
        {
            n.mantissa /= 10;
            n.exponent++;
        }
        return n;
    }

    /// True when the value is zero.
    bool isZero() const
    {
        return mantissa == 0;
    }

    /// -1, 0 or 1 according to the sign of the value.
    int sign() const
    {
        return mantissa < 0 ? -1 : (mantissa > 0 ? 1 : 0);
    }

    /// True when the value is a whole number (`1.0`, `1e2` and `-0` are).
    bool isInteger() const
    {
        return exponent >= 0 || mantissa == 0;
    }

    /// Exact three-way comparison.
    int opCmp(const Number o) const
    {
        immutable sa = sign(), sb = o.sign();
        if (sa != sb)
            return sa < sb ? -1 : 1;
        if (sa == 0)
            return 0;
        if (exponent == o.exponent)
            return mantissa < o.mantissa ? -1 : (mantissa > o.mantissa ? 1 : 0);
        if (exponent > o.exponent)
        {
            auto scaled = mantissa * pow10(exponent - o.exponent);
            return scaled < o.mantissa ? -1 : (scaled > o.mantissa ? 1 : 0);
        }
        auto scaled = o.mantissa * pow10(o.exponent - exponent);
        return mantissa < scaled ? -1 : (mantissa > scaled ? 1 : 0);
    }

    /// Exact equality (canonical forms compare structurally).
    bool opEquals(const Number o) const
    {
        return exponent == o.exponent && mantissa == o.mantissa;
    }

    /// Hash consistent with `opEquals`.
    size_t toHash() const nothrow @trusted
    {
        return mantissa.toHash() * 31 + cast(size_t) exponent;
    }

    /// True when `this / divisor` is a whole number. `divisor` must be non-zero.
    bool isMultipleOf(const Number divisor) const
    {
        if (mantissa == 0)
            return true;
        immutable d = exponent - divisor.exponent;
        if (d >= 0)
        {
            if (divisor.mantissa == 1 || divisor.mantissa == -1)
                return true;
            return (mantissa * pow10(d)) % divisor.mantissa == 0;
        }
        return mantissa % (divisor.mantissa * pow10(-d)) == 0;
    }

    /// The value as a `long` when it is a whole number, saturating at the
    /// `long` range; negative values saturate to 0 (used for count keywords).
    long toCount() const
    {
        if (sign() <= 0)
            return 0;
        if (!isInteger())
            return -1;
        if (exponent > 18)
            return long.max;
        auto v = mantissa * pow10(exponent);
        if (v > BigInt(long.max))
            return long.max;
        return v.toLong();
    }

    /// Decimal text, `mantissa` followed by `e` and the exponent.
    string toString() const
    {
        import std.conv : to;

        return mantissa.to!string ~ "e" ~ exponent.to!string;
    }
}

private __gshared BigInt[] pow10Cache;

/// 10 raised to `n` (n >= 0), cached.
BigInt pow10(int n)
{
    synchronized
    {
        if (pow10Cache.length == 0)
            pow10Cache = [BigInt(1)];
        while (pow10Cache.length <= n)
            pow10Cache ~= pow10Cache[$ - 1] * 10;
        return pow10Cache[n];
    }
}

unittest
{
    auto a = Number.fromDigits(false, "10", 0); // 10
    auto b = Number.fromDigits(false, "1", 1); // 1e1
    assert(a == b);
    assert(Number.fromDigits(false, "100", -2) == Number.fromLong(1));
    assert(Number.fromDigits(true, "0", 0) == Number.fromLong(0));
    assert(Number.fromDigits(false, "15", -1).isInteger == false);
    assert(Number.fromDigits(false, "10", -1).isInteger);
}

unittest
{
    // 0.3 is exactly 3000 * 0.0001
    auto x = Number.fromDigits(false, "3", -1);
    auto y = Number.fromDigits(false, "1", -4);
    assert(x.isMultipleOf(y));
    auto z = Number.fromDigits(false, "7", -5);
    assert(!x.isMultipleOf(z));
    assert(Number.fromLong(0).isMultipleOf(y));
    auto big = Number.fromDigits(false, "1", 309);
    auto lim = Number.fromDigits(false, "1", 308);
    assert(big > lim && lim < big);
}

unittest
{
    assert(Number.fromDigits(true, "5", 0) < Number.fromLong(0));
    assert(Number.fromDigits(true, "5", 0) < Number.fromDigits(true, "4", 0));
    assert(Number.fromDigits(false, "25", -1) > Number.fromLong(2));
    assert(Number.fromDigits(false, "2", 0).toCount() == 2);
    assert(Number.fromDigits(false, "2", -1).toCount() == -1);
}
