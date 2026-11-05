/**
 * Signed arbitrary-precision integer type built on `bigint.magnitude`.
 */
module bigint.integer;

import bigint.decimal;
import bigint.magnitude;

/// A signed integer of unbounded size (sign-magnitude, base-10^9 limbs).
struct BigInt
{
    private bool _neg;       // never true for zero
    private const(uint)[] _mag; // shared, immutable-by-convention magnitude

    /// Builds a value from a machine integer.
    this(long v) pure nothrow @safe
    {
        _neg = v < 0;
        ulong u = v < 0 ? -cast(ulong) v : cast(ulong) v;
        uint[] m;
        while (u != 0)
        {
            m ~= cast(uint)(u % BASE);
            u /= BASE;
        }
        _mag = m;
    }

    /// Parses `-?[0-9]+` (leading zeros and `-0` accepted).
    /// Throws `Exception` on malformed text.
    this(scope const(char)[] text) pure @safe
    {
        size_t start = (text.length && text[0] == '-') ? 1 : 0;
        if (start >= text.length)
            throw new Exception("bigint: empty number");
        foreach (c; text[start .. $])
            if (c < '0' || c > '9')
                throw new Exception("bigint: invalid digit");
        auto p = parseDecimal(text);
        _neg = p.negative;
        _mag = p.magnitude;
    }

    private this(bool neg, const(uint)[] mag) pure nothrow @safe
    {
        _mag = mag;
        _neg = mag.length != 0 && neg;
    }

    /// True iff the value is zero.
    bool isZero() const pure nothrow @nogc @safe { return _mag.length == 0; }
    /// True iff the value is negative.
    bool isNegative() const pure nothrow @nogc @safe { return _neg; }
    /// -1, 0 or 1.
    int sign() const pure nothrow @nogc @safe { return _mag.length == 0 ? 0 : (_neg ? -1 : 1); }
    /// The little-endian base-10^9 magnitude.
    const(uint)[] magnitude() const pure nothrow @nogc @safe { return _mag; }

    /// Canonical decimal text.
    string toString() const pure nothrow @safe { return toDecimal(_neg, _mag); }

    /// Appends the canonical decimal text to `buf`.
    void toString(Sink)(scope Sink sink) const
    {
        sink(toString());
    }

    /// Unary minus (no magnitude copy).
    BigInt opUnary(string op : "-")() const pure nothrow @safe
    {
        return BigInt(!_neg, _mag);
    }

    /// Unary plus.
    BigInt opUnary(string op : "+")() const pure nothrow @safe { return this; }

    /// Absolute value.
    BigInt abs() const pure nothrow @safe { return BigInt(false, _mag); }

    /// Equality by numeric value.
    bool opEquals(const BigInt rhs) const pure nothrow @nogc @safe
    {
        return _neg == rhs._neg && compare(_mag, rhs._mag) == 0;
    }

    /// Three-way comparison by numeric value.
    int opCmp(const BigInt rhs) const pure nothrow @nogc @safe
    {
        if (_neg != rhs._neg)
            return _neg ? -1 : 1;
        immutable c = compare(_mag, rhs._mag);
        return _neg ? -c : c;
    }

    /// Hash consistent with `opEquals`.
    size_t toHash() const nothrow @safe
    {
        size_t h = _neg ? 1 : 0;
        foreach (l; _mag)
            h = h * 1_000_003 + l;
        return h;
    }

    /// `+`, `-`, `*`, `/` (truncating) and `%` (sign of the dividend).
    /// Division by zero throws `Exception`.
    BigInt opBinary(string op)(const BigInt rhs) const pure @safe
    {
        static if (op == "+")
            return addSigned(_neg, _mag, rhs._neg, rhs._mag);
        else static if (op == "-")
            return addSigned(_neg, _mag, !rhs._neg, rhs._mag);
        else static if (op == "*")
            return BigInt(_neg != rhs._neg, mul(_mag, rhs._mag));
        else static if (op == "/")
            return divMod(this, rhs)[0];
        else static if (op == "%")
            return divMod(this, rhs)[1];
        else static if (op == "^^")
            return pow(this, rhs);
        else
            static assert(false, "unsupported operator " ~ op);
    }

    /// Operators with a machine-integer right-hand side.
    BigInt opBinary(string op)(long rhs) const pure @safe
    {
        return opBinary!op(BigInt(rhs));
    }

    /// Compound assignment.
    ref BigInt opOpAssign(string op, T)(T rhs) pure @safe
    {
        this = opBinary!op(rhs);
        return this;
    }
}

/// `a + b` where the second operand's sign is given separately.
private BigInt addSigned(bool an, const(uint)[] am, bool bn, const(uint)[] bm) pure nothrow @safe
{
    if (an == bn)
        return BigInt(an, add(am, bm));
    immutable c = compare(am, bm);
    if (c == 0)
        return BigInt(false, null);
    return c > 0 ? BigInt(an, sub(am, bm)) : BigInt(bn, sub(bm, am));
}

/**
 * Truncating division: returns `[quotient, remainder]` with
 * `a == q*b + r`, `|r| < |b|` and `r` zero or of the sign of `a`.
 * Throws `Exception` if `b` is zero.
 */
BigInt[2] divMod(const BigInt a, const BigInt b) pure @safe
{
    if (b.isZero)
        throw new Exception("bigint: division by zero");
    auto dm = bigint.magnitude.divMod(a._mag, b._mag);
    return [BigInt(a._neg != b._neg, dm.quotient), BigInt(a._neg, dm.remainder)];
}

/**
 * `base ^ exponent`. `0 ^ 0 == 1`. Throws `Exception` for a negative
 * exponent, or one too large to be represented (> ulong.max).
 */
BigInt pow(const BigInt base, const BigInt exponent) pure @safe
{
    if (exponent.isNegative)
        throw new Exception("bigint: negative exponent");
    return pow(base, foldExponent(exponent._mag));
}

/// `base ^ exponent` for a machine exponent.
BigInt pow(const BigInt base, ulong exponent) pure @safe
{
    immutable odd = (exponent & 1) != 0;
    return BigInt(base._neg && odd, bigint.magnitude.pow(base._mag, exponent));
}

private ulong foldExponent(scope const(uint)[] mag) pure @safe
{
    if (mag.length > 3)
        throw new Exception("bigint: exponent too large");
    ulong e = 0;
    foreach_reverse (l; mag)
    {
        immutable ulong hi = e;
        if (hi > (ulong.max - l) / BASE)
            throw new Exception("bigint: exponent too large");
        e = hi * BASE + l;
    }
    return e;
}
