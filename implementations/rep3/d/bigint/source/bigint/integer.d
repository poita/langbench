/**
 * The `BigInt` value type: a sign plus a base-10^9 magnitude.
 *
 * Example:
 * ---
 * import bigint;
 *
 * auto a = BigInt("123456789012345678901234567890");
 * auto b = BigInt("-987654321");
 * assert((a + b).toString() == "123456789012345678900246913569");
 * assert((a / b).toString() == "-124999998873437499901");
 * assert(BigInt(2) ^^ 100 == BigInt("1267650600228229401496703205376"));
 * ---
 */
module bigint.integer;

import bigint.magnitude;
import bigint.division;
import bigint.decimal;

/// Thrown for division by zero and other invalid arithmetic requests.
class BigIntException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/**
 * Arbitrary-precision signed integer.
 *
 * Values are immutable in effect: no operation modifies the magnitude storage
 * of an existing value, so copies of a `BigInt` may safely share it.
 * Zero is never negative.
 */
struct BigInt
{
    private Limbs _mag; // canonical magnitude, little-endian base 10^9
    private bool _neg; // true only for strictly negative values

    /// Constructs from a decimal string `-?[0-9]+` (leading zeros and `-0` allowed).
    this(scope const(char)[] text) pure @safe
    {
        if (text.length > 0 && text[0] == '-')
        {
            _mag = parseMagnitude(text[1 .. $]);
            _neg = _mag.length != 0;
        }
        else
        {
            _mag = parseMagnitude(text);
            _neg = false;
        }
    }

    /// Constructs from a machine integer.
    this(long value) pure nothrow @safe
    {
        _neg = value < 0;
        ulong m = _neg ? -cast(ulong) value : cast(ulong) value;
        while (m != 0)
        {
            _mag ~= cast(uint)(m % BASE);
            m /= BASE;
        }
    }

    // Takes ownership of (shares) `mag`, which must already be canonical.
    private this(const(uint)[] mag, bool neg) pure nothrow @trusted
    {
        _mag = cast(Limbs) mag;
        _neg = neg && mag.length != 0;
    }

    /// True if the value is zero.
    @property bool isZero() const pure nothrow @nogc @safe
    {
        return _mag.length == 0;
    }

    /// True if the value is strictly less than zero.
    @property bool isNegative() const pure nothrow @nogc @safe
    {
        return _neg;
    }

    /// -1, 0 or 1 according to the sign of the value.
    @property int sign() const pure nothrow @nogc @safe
    {
        return _mag.length == 0 ? 0 : (_neg ? -1 : 1);
    }

    /// True if the value is odd.
    @property bool isOdd() const pure nothrow @nogc @safe
    {
        return _mag.length != 0 && (_mag[0] & 1) != 0;
    }

    /// The magnitude limbs (little-endian, base 10^9). Do not modify.
    @property const(uint)[] limbs() const pure nothrow @nogc @safe
    {
        return _mag;
    }

    /// Converts to `ulong`. Throws `BigIntException` if negative or too large.
    ulong toUlong() const pure @safe
    {
        if (_neg)
            throw new BigIntException("negative value does not fit in ulong");
        if (_mag.length > 3)
            throw new BigIntException("value does not fit in ulong");
        ulong r = 0;
        foreach_reverse (l; _mag)
        {
            immutable ulong hi = r;
            // Detect overflow of r * BASE + l.
            if (hi > (ulong.max - l) / BASE)
                throw new BigIntException("value does not fit in ulong");
            r = hi * BASE + l;
        }
        return r;
    }

    /// Unary `-` and `+`. Negation shares the magnitude (no copy).
    BigInt opUnary(string op)() const pure nothrow @safe
        if (op == "-" || op == "+")
    {
        static if (op == "-")
            return BigInt(_mag, !_neg);
        else
            return this;
    }

    /// Absolute value (shares the magnitude).
    BigInt abs() const pure nothrow @safe
    {
        return BigInt(_mag, false);
    }

    /// Binary `+`, `-`, `*`, `/`, `%` between two `BigInt`s.
    BigInt opBinary(string op)(const BigInt rhs) const pure @safe
        if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%")
    {
        static if (op == "+")
            return addSigned(_mag, _neg, rhs._mag, rhs._neg);
        else static if (op == "-")
            return addSigned(_mag, _neg, rhs._mag, !rhs._neg);
        else static if (op == "*")
            return BigInt(mulMag(_mag, rhs._mag), _neg != rhs._neg);
        else
        {
            BigInt q, r;
            divMod(this, rhs, q, r);
            static if (op == "/")
                return q;
            else
                return r;
        }
    }

    /// `a ^^ e` for a non-negative machine-integer exponent.
    BigInt opBinary(string op : "^^")(ulong e) const pure @safe
    {
        return pow(this, e);
    }

    /// Three-way numeric comparison (usable with `<`, `>`, `<=`, `>=`).
    int opCmp(const BigInt rhs) const pure nothrow @nogc @safe
    {
        if (_neg != rhs._neg)
            return _neg ? -1 : 1;
        immutable int c = cmpMag(_mag, rhs._mag);
        return _neg ? -c : c;
    }

    /// Numeric equality.
    bool opEquals(const BigInt rhs) const pure nothrow @nogc @safe
    {
        return _neg == rhs._neg && _mag == rhs._mag;
    }

    /// Hash consistent with `opEquals`.
    size_t toHash() const nothrow @safe
    {
        size_t h = _neg ? 1 : 0;
        foreach (l; _mag)
            h = h * 1_000_003 + l;
        return h;
    }

    /// Canonical decimal text: no leading zeros, never "-0".
    string toString() const pure nothrow @trusted
    {
        immutable size_t len = decimalLength(_mag) + (_neg ? 1 : 0);
        auto buf = new char[len];
        size_t pos = 0;
        if (_neg)
            buf[pos++] = '-';
        pos += formatMagnitude(_mag, buf[pos .. $]);
        assert(pos == len);
        return cast(string) buf;
    }

    /**
     * Appends the canonical decimal text to an output range of `char`
     * (anything with `put`, e.g. `std.array.Appender!(char[])`).
     */
    void writeTo(Sink)(ref Sink sink) const
    {
        import std.range.primitives : put;

        if (_neg)
            put(sink, '-');
        // Format in a temporary buffer so that the sink sees one `put`.
        auto buf = new char[decimalLength(_mag)];
        immutable n = formatMagnitude(_mag, buf);
        put(sink, buf[0 .. n]);
    }
}

private BigInt addSigned(const(uint)[] a, bool aNeg, const(uint)[] b, bool bNeg)
    pure nothrow @safe
{
    if (aNeg == bNeg)
        return BigInt(addMag(a, b), aNeg);
    immutable c = cmpMag(a, b);
    if (c == 0)
        return BigInt.init;
    if (c > 0)
        return BigInt(subMag(a, b), aNeg);
    return BigInt(subMag(b, a), bNeg);
}

/**
 * Truncating division: `q = a / b`, `r = a % b`, so that
 * `a == q * b + r`, `|r| < |b|` and `r` is zero or has the sign of `a`.
 *
 * Throws: `BigIntException` if `b` is zero.
 */
void divMod(const BigInt a, const BigInt b, out BigInt q, out BigInt r) pure @safe
{
    if (b.isZero)
        throw new BigIntException("division by zero");
    Limbs qm, rm;
    divModMag(a._mag, b._mag, qm, rm);
    q = BigInt(qm, a._neg != b._neg);
    r = BigInt(rm, a._neg);
}

/**
 * Raises `base` to the power `e` by left-to-right binary exponentiation.
 *
 * `pow(x, 0) == 1` for every `x`, including zero.
 */
BigInt pow(const BigInt base, ulong e) pure @safe
{
    if (e == 0)
        return BigInt(1);
    immutable bool neg = base._neg && (e & 1) != 0;
    if (base.isZero)
        return BigInt.init;
    if (base._mag.length == 1 && base._mag[0] == 1)
        return BigInt(base._mag.dup, neg);

    // Left-to-right: start from |base| at the top bit.
    int top = 63;
    while (((e >> top) & 1) == 0)
        --top;
    Limbs acc = base._mag.dup;
    for (int bit = top - 1; bit >= 0; --bit)
    {
        acc = mulMag(acc, acc);
        if ((e >> bit) & 1)
            acc = mulMag(acc, base._mag);
    }
    return BigInt(acc, neg);
}
