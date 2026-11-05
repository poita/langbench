/**
 * The signed arbitrary-precision integer type `BigInt`.
 *
 * Values are immutable in spirit: every operation returns a new value, and
 * magnitude arrays are shared (never copied) between values where possible,
 * e.g. negation and subtraction only flip the sign flag.
 */
module bigint.integer;

import bigint.limbs;

/// Thrown by division and exponentiation on invalid arguments, and by
/// parsing on malformed input.
class BigIntException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// A signed arbitrary-precision integer (sign + base-10^9 magnitude).
struct BigInt
{
    private bool _neg;       // never true for zero
    private const(uint)[] _mag; // little-endian, trimmed

    /// Builds a `BigInt` from a machine integer.
    this(long v) pure nothrow @safe
    {
        _neg = v < 0;
        ulong u = _neg ? -cast(ulong) v : cast(ulong) v;
        uint[] m;
        while (u)
        {
            m ~= cast(uint)(u % base);
            u /= base;
        }
        _mag = m;
    }

    /**
     * Parses a decimal string matching `-?[0-9]+`. Leading zeros and `-0`
     * are accepted. Throws `BigIntException` on malformed input.
     */
    this(const(char)[] s) pure @safe
    {
        bool neg = false;
        if (s.length && s[0] == '-')
        {
            neg = true;
            s = s[1 .. $];
        }
        if (s.length == 0)
            throw new BigIntException("empty number");
        uint[] m;
        if (!parseMag(s, m))
            throw new BigIntException("invalid digit in number");
        _mag = m;
        _neg = neg && m.length != 0;
    }

    private this(bool neg, const(uint)[] mag) pure nothrow @safe
    {
        _mag = mag;
        _neg = neg && mag.length != 0;
    }

    /// True if the value is zero.
    @property bool isZero() const pure nothrow @nogc @safe
    {
        return _mag.length == 0;
    }

    /// True if the value is strictly negative (zero is never negative).
    @property bool isNegative() const pure nothrow @nogc @safe
    {
        return _neg;
    }

    /// True if the value is odd.
    @property bool isOdd() const pure nothrow @nogc @safe
    {
        return _mag.length != 0 && (_mag[0] & 1);
    }

    /// Number of base-10^9 limbs in the magnitude.
    @property size_t limbCount() const pure nothrow @nogc @safe
    {
        return _mag.length;
    }

    /// Returns `-1`, `0` or `1` according to the sign of the value.
    @property int sign() const pure nothrow @nogc @safe
    {
        return _mag.length == 0 ? 0 : (_neg ? -1 : 1);
    }

    /// Absolute value (shares storage).
    BigInt abs() const pure nothrow @safe
    {
        return BigInt(false, _mag);
    }

    /**
     * Converts to `long`. Returns `false` (and leaves `result` unspecified)
     * if the value does not fit.
     */
    bool toLong(out long result) const pure nothrow @nogc @safe
    {
        if (_mag.length > 3)
            return false;
        ulong u = 0;
        foreach_reverse (l; _mag)
        {
            if (u > (ulong.max - l) / base)
                return false;
            u = u * base + l;
        }
        if (_neg)
        {
            if (u > cast(ulong) long.max + 1)
                return false;
            result = cast(long)(-u);
        }
        else
        {
            if (u > long.max)
                return false;
            result = cast(long) u;
        }
        return true;
    }

    /// Unary `-` and `+`.
    BigInt opUnary(string op)() const pure nothrow @safe
    if (op == "-" || op == "+")
    {
        static if (op == "-")
            return BigInt(!_neg, _mag);
        else
            return this;
    }

    /// Binary `+ - * / %` with another `BigInt`.
    BigInt opBinary(string op)(const BigInt rhs) const pure @safe
    if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%")
    {
        static if (op == "+")
            return addSigned(this, rhs._neg, rhs._mag);
        else static if (op == "-")
            return addSigned(this, !rhs._neg, rhs._mag);
        else static if (op == "*")
            return BigInt(_neg != rhs._neg, mulMag(_mag, rhs._mag));
        else
        {
            auto qr = divMod(this, rhs);
            return op == "/" ? qr.quotient : qr.remainder;
        }
    }

    /// Binary operators with a machine integer on the right.
    BigInt opBinary(string op)(long rhs) const pure @safe
    if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%")
    {
        return opBinary!op(BigInt(rhs));
    }

    /// `a ^^ e` for a non-negative machine-integer exponent.
    BigInt opBinary(string op : "^^")(ulong e) const pure nothrow @safe
    {
        return pow(this, e);
    }

    /// Three-way comparison.
    int opCmp(const BigInt rhs) const pure nothrow @nogc @safe
    {
        if (_neg != rhs._neg)
            return _neg ? -1 : 1;
        immutable c = cmpMag(_mag, rhs._mag);
        return _neg ? -c : c;
    }

    /// Equality.
    bool opEquals(const BigInt rhs) const pure nothrow @nogc @safe
    {
        return _neg == rhs._neg && cmpMag(_mag, rhs._mag) == 0;
    }

    /// Hash consistent with `opEquals`.
    size_t toHash() const nothrow @safe
    {
        size_t h = _neg ? 1 : 0;
        foreach (l; _mag)
            h = h * 1_000_003 + l;
        return h;
    }

    /// Writes the canonical decimal form (no leading zeros, never `-0`) to an
    /// output range of `char`.
    void toDecimal(Sink)(ref Sink sink) const
    {
        import std.range.primitives : put;

        if (_neg)
            put(sink, '-');
        putMag(sink, _mag);
    }

    /// Canonical decimal string.
    string toString() const pure @safe
    {
        import std.array : appender;

        auto app = appender!string();
        toDecimal(app);
        return app[];
    }

    /// Support for `std.format`'s `%s`.
    void toString(Writer, Char)(ref Writer w, scope const ref FormatSpec!Char) const
    {
        toDecimal(w);
    }
}

import std.format : FormatSpec;

private BigInt addSigned(const BigInt a, bool bNeg, const(uint)[] bMag) pure @safe
{
    if (a._neg == bNeg)
        return BigInt(a._neg, addMag(a._mag, bMag));
    immutable c = cmpMag(a._mag, bMag);
    if (c == 0)
        return BigInt.init;
    if (c > 0)
        return BigInt(a._neg, subMag(a._mag, bMag));
    return BigInt(bNeg, subMag(bMag, a._mag));
}

/// Quotient and remainder of a truncating division.
struct DivMod
{
    BigInt quotient;  /// `a / b`, truncated toward zero
    BigInt remainder; /// `a % b`, same sign as `a` (or zero)
}

/**
 * Truncating division: `a == quotient * b + remainder`, `|remainder| < |b|`,
 * and the remainder is zero or has the sign of `a`.
 *
 * Throws: `BigIntException` if `b` is zero.
 */
DivMod divMod(const BigInt a, const BigInt b) pure @safe
{
    if (b.isZero)
        throw new BigIntException("division by zero");
    auto r = divModMag(a._mag, b._mag);
    return DivMod(BigInt(a._neg != b._neg, r.quotient), BigInt(a._neg, r.remainder));
}

/**
 * Raises `base_` to the power `e` using left-to-right binary exponentiation.
 * `pow(x, 0) == 1` for every `x`, including zero.
 */
BigInt pow(const BigInt base_, ulong e) pure nothrow @safe
{
    if (e == 0)
        return BigInt(1);
    if (base_.isZero)
        return BigInt.init;
    immutable bool neg = base_._neg && (e & 1);
    // |a| == 1
    if (base_._mag.length == 1 && base_._mag[0] == 1)
        return BigInt(neg, base_._mag);

    const(uint)[] acc = base_._mag;
    int top = 63;
    while (!((e >> top) & 1))
        --top;
    for (int bit = top - 1; bit >= 0; --bit)
    {
        acc = mulMag(acc, acc);
        if ((e >> bit) & 1)
            acc = mulMag(acc, base_._mag);
    }
    return BigInt(neg, acc);
}
