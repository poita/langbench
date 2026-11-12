/**
 * The signed arbitrary-precision integer type `BigInt`.
 *
 * ---
 * import bigint;
 *
 * auto a = BigInt("-123456789012345678901234567890");
 * auto b = BigInt(987654321);
 * assert((a * b).toString == "-121932631124828532112482853211126352690");
 * assert(a / b == BigInt("-124999998873437499901"));
 * assert(BigInt(2) ^^ BigInt(100) == BigInt("1267650600228229401496703205376"));
 * ---
 *
 * `BigInt` is an immutable-by-construction value: every operation allocates a
 * new magnitude, so copies may share storage safely. The default value is zero.
 * Division truncates toward zero and the remainder takes the sign of the
 * dividend (C semantics).
 */
module bigint.bigint;

import bigint.decimal;
import bigint.exceptions;
import bigint.magnitude;

/// Signed arbitrary-precision integer.
struct BigInt
{
    private bool _neg; // never true when _mag is empty
    private const(uint)[] _mag; // normalised, little-endian, base 10^9

    // ---- construction ---------------------------------------------------

    /// Constructs from a machine integer.
    this(long value) @safe pure nothrow
    {
        _neg = value < 0;
        ulong u = _neg ? -cast(ulong) value : cast(ulong) value;
        uint[] m;
        while (u != 0)
        {
            m ~= cast(uint)(u % BASE);
            u /= BASE;
        }
        _mag = m;
    }

    /**
     * Parses a decimal integer: an optional `-` followed by one or more digits.
     * Leading zeros and `-0` are accepted. Throws `ParseException` otherwise.
     */
    this(scope const(char)[] text) @safe pure
    {
        bool neg = false;
        if (text.length > 0 && text[0] == '-')
        {
            neg = true;
            text = text[1 .. $];
        }
        _mag = parseDigits(text);
        _neg = neg && _mag.length != 0;
    }

    private this(bool neg, const(uint)[] mag) @safe pure nothrow
    {
        _mag = mag;
        _neg = neg && mag.length != 0;
    }

    // ---- inspection -----------------------------------------------------

    /// True if the value is zero.
    bool isZero() const @safe pure nothrow @nogc
    {
        return _mag.length == 0;
    }

    /// True if the value is strictly negative.
    bool isNegative() const @safe pure nothrow @nogc
    {
        return _neg;
    }

    /// -1, 0 or 1 according to the sign of the value.
    int sign() const @safe pure nothrow @nogc
    {
        return _neg ? -1 : (_mag.length == 0 ? 0 : 1);
    }

    /// True if the value is odd.
    bool isOdd() const @safe pure nothrow @nogc
    {
        return _mag.length != 0 && (_mag[0] & 1) != 0;
    }

    /// Number of decimal digits of the absolute value (1 for zero).
    size_t decimalDigits() const @safe pure nothrow @nogc
    {
        return digitCount(_mag);
    }

    // ---- text output ----------------------------------------------------

    /// Canonical decimal representation (no leading zeros, never "-0").
    string toString() const @safe pure nothrow
    {
        auto digits = formatDigits(_mag);
        if (!_neg)
            return (() @trusted => cast(string) digits)();
        auto s = new char[digits.length + 1];
        s[0] = '-';
        s[1 .. $] = digits;
        return (() @trusted => cast(string) s)();
    }

    /// Sink-based output, compatible with `std.format`.
    void toString(scope void delegate(scope const(char)[]) sink) const
    {
        if (_neg)
            sink("-");
        sink(formatDigits(_mag));
    }

    // ---- comparison -----------------------------------------------------

    /// Three-way numeric comparison.
    int opCmp(const BigInt rhs) const @safe pure nothrow @nogc
    {
        if (_neg != rhs._neg)
            return _neg ? -1 : 1;
        const c = cmpMag(_mag, rhs._mag);
        return _neg ? -c : c;
    }

    /// Numeric equality.
    bool opEquals(const BigInt rhs) const @safe pure nothrow @nogc
    {
        return _neg == rhs._neg && _mag == rhs._mag;
    }

    /// Hash consistent with `opEquals`.
    size_t toHash() const @safe pure nothrow @nogc
    {
        size_t h = _neg ? 0x9e3779b9 : 0;
        foreach (limb; _mag)
            h = h * 31 + limb;
        return h;
    }

    // ---- arithmetic -----------------------------------------------------

    /// Unary `-` and `+`.
    BigInt opUnary(string op)() const @safe pure nothrow
    if (op == "-" || op == "+")
    {
        static if (op == "-")
            return BigInt(!_neg, _mag);
        else
            return this;
    }

    /// Absolute value.
    BigInt abs() const @safe pure nothrow
    {
        return BigInt(false, _mag);
    }

    /// `+`, `-`, `*`, `/` (truncating), `%` (sign of the dividend) and `^^`.
    BigInt opBinary(string op)(const BigInt rhs) const @safe pure
    if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "^^")
    {
        static if (op == "+")
            return addSigned(this, rhs, false);
        else static if (op == "-")
            return addSigned(this, rhs, true);
        else static if (op == "*")
            return BigInt(_neg != rhs._neg, mulMag(_mag, rhs._mag));
        else static if (op == "/")
        {
            BigInt q, r;
            divMod(this, rhs, q, r);
            return q;
        }
        else static if (op == "%")
        {
            BigInt q, r;
            divMod(this, rhs, q, r);
            return r;
        }
        else
            return pow(this, rhs);
    }

    /// Operator-assignment forms of the binary operators.
    ref BigInt opOpAssign(string op)(const BigInt rhs) @safe pure
    {
        this = opBinary!op(rhs);
        return this;
    }

    /// Binary operators with a machine-integer right operand.
    BigInt opBinary(string op)(long rhs) const @safe pure
    {
        return opBinary!op(BigInt(rhs));
    }

    /**
     * Computes the quotient (truncated toward zero) and remainder (sign of the
     * dividend) of `a / b` together, so that `a == q * b + r`.
     * Throws `DivisionByZeroException` if `b` is zero.
     */
    static void divMod(const BigInt a, const BigInt b, out BigInt quotient, out BigInt remainder) @safe pure
    {
        if (b.isZero)
            throw new DivisionByZeroException;
        uint[] q, r;
        divModMag(a._mag, b._mag, q, r);
        quotient = BigInt(a._neg != b._neg, q);
        remainder = BigInt(a._neg, r);
    }

    /**
     * Raises `base` to the power `exponent` by binary exponentiation.
     *
     * `x ^ 0 == 1` for every `x` (including zero). Throws
     * `NegativeExponentException` for a negative exponent and
     * `ExponentTooLargeException` if `|base| > 1` and the exponent does not fit
     * in 64 bits (such a power could not be represented anyway).
     */
    static BigInt pow(const BigInt base, const BigInt exponent) @safe pure
    {
        if (exponent.isNegative)
            throw new NegativeExponentException;
        if (exponent.isZero)
            return BigInt(1);
        // Trivial bases work for any exponent size.
        if (base.isZero)
            return base;
        if (base._mag.length == 1 && base._mag[0] == 1)
            return BigInt(base._neg && exponent.isOdd, base._mag);
        // |exponent| must fit in 64 bits: at most 3 limbs, checked for overflow.
        if (exponent._mag.length > 3)
            throw new ExponentTooLargeException;
        ulong e = 0;
        foreach_reverse (limb; exponent._mag)
        {
            if (e > (ulong.max - limb) / BASE)
                throw new ExponentTooLargeException;
            e = e * BASE + limb;
        }
        return pow(base, e);
    }

    /// ditto
    static BigInt pow(const BigInt base, ulong exponent) @safe pure
    {
        if (exponent == 0)
            return BigInt(1);
        if (base.isZero)
            return base;
        const resultNeg = base._neg && (exponent & 1) != 0;
        const(uint)[] result = [1u];
        // Left-to-right square-and-multiply.
        bool started = false;
        for (int bit = 63; bit >= 0; --bit)
        {
            if (started)
                result = mulMag(result, result);
            if ((exponent >> bit) & 1)
            {
                result = started ? mulMag(result, base._mag) : base._mag;
                started = true;
            }
        }
        return BigInt(resultNeg, result);
    }

    private static BigInt addSigned(const BigInt a, const BigInt b, bool negateB) @safe pure nothrow
    {
        const bNeg = b._neg != negateB && !b.isZero;
        if (a._neg == bNeg)
            return BigInt(a._neg, addMag(a._mag, b._mag));
        // Opposite signs: subtract the smaller magnitude from the larger.
        const c = cmpMag(a._mag, b._mag);
        if (c == 0)
            return BigInt();
        return c > 0 ? BigInt(a._neg, subMag(a._mag, b._mag)) : BigInt(bNeg, subMag(b._mag, a._mag));
    }
}

/// Power function helper, equivalent to `base ^^ exponent`.
BigInt pow(const BigInt base, const BigInt exponent) @safe pure
{
    return BigInt.pow(base, exponent);
}

// ---------------------------------------------------------------------------

unittest
{
    // the module-level documentation example
    auto a = BigInt("-123456789012345678901234567890");
    auto b = BigInt(987654321);
    assert((a * b).toString == "-121932631124828532112482853211126352690");
    assert(a / b == BigInt("-124999998873437499901"));
    assert(BigInt(2) ^^ BigInt(100) == BigInt("1267650600228229401496703205376"));
}

unittest
{
    assert(BigInt("0").toString == "0");
    assert(BigInt("-0").toString == "0");
    assert(BigInt("-000").toString == "0");
    assert(BigInt("007").toString == "7");
    assert(BigInt("-000123").toString == "-123");
    assert(BigInt().toString == "0");
    assert(BigInt(long.min).toString == "-9223372036854775808");
    assert(BigInt(long.max).toString == "9223372036854775807");
    assert(BigInt(-5) == BigInt("-5"));
    assert(BigInt("-0") == BigInt("0"));
    assert(!BigInt("-0").isNegative);
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!ParseException(BigInt(""));
    assertThrown!ParseException(BigInt("-"));
    assertThrown!ParseException(BigInt("+5"));
    assertThrown!ParseException(BigInt("1 2"));
    assertThrown!ParseException(BigInt("--1"));
}

unittest
{
    // spec examples
    assert(BigInt("12") + BigInt("30") == BigInt(42));
    assert(BigInt(5) - BigInt(7) == BigInt(-2));
    assert((BigInt("-0") + BigInt("0")).toString == "0");
    assert((BigInt(-5) * BigInt(0)).toString == "0");
    assert((BigInt("99999999999999999999") + BigInt(1)).toString == "100000000000000000000");
    assert((BigInt("1000000000000000000000000000000") - BigInt(1)).toString
            == "999999999999999999999999999999");
    assert((BigInt("-123456789012345678901234567890") * BigInt("987654321098765432109876543210")).toString
            == "-121932631137021795226185032733622923332237463801111263526900");
}

unittest
{
    // C division semantics
    static void check(long a, long b)
    {
        auto q = BigInt(a) / BigInt(b);
        auto r = BigInt(a) % BigInt(b);
        assert(q == BigInt(a / b), "quotient");
        assert(r == BigInt(a % b), "remainder");
        assert(!q.isNegative || !q.isZero);
    }

    foreach (a; [7L, -7, 1, -1, 0, 100, -100, 1_000_000_007, -999_999_999_999])
        foreach (b; [2L, -2, 3, -3, 7, -7, 1, -1, 1_000_000_000, -1_000_000_001])
            check(a, b);
    assert((BigInt(-1) / BigInt(2)).toString == "0");
    assert((BigInt(-7) % BigInt(7)).toString == "0");
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!DivisionByZeroException(BigInt(1) / BigInt(0));
    assertThrown!DivisionByZeroException(BigInt(0) % BigInt(0));
    assertThrown!DivisionByZeroException(BigInt(5) / BigInt("-0"));
    assertThrown!NegativeExponentException(BigInt(2) ^^ BigInt(-1));
    assertThrown!NegativeExponentException(BigInt(0) ^^ BigInt("-100000000000000000000"));
    assertThrown!ExponentTooLargeException(BigInt(2) ^^ BigInt("1000000000000000000000000000000"));
}

unittest
{
    // exponentiation
    assert((BigInt(2) ^^ BigInt(10)).toString == "1024");
    assert((BigInt(0) ^^ BigInt(0)).toString == "1");
    assert((BigInt(0) ^^ BigInt(5)).toString == "0");
    assert((BigInt(-2) ^^ BigInt(3)).toString == "-8");
    assert((BigInt(-2) ^^ BigInt(2)).toString == "4");
    assert((BigInt(-1) ^^ BigInt(999)).toString == "-1");
    assert((BigInt(-1) ^^ BigInt("100000000000000000000")).toString == "1");
    assert((BigInt(5) ^^ BigInt("-0")).toString == "1");
    assert((BigInt("-0") ^^ BigInt("-00")).toString == "1");
    assert((BigInt(2) ^^ BigInt(100)).toString == "1267650600228229401496703205376");
    assert((BigInt(10) ^^ BigInt(50)).toString == "1" ~ "00000000000000000000000000000000000000000000000000");
    assert((BigInt(3) ^^ BigInt(0003)).toString == "27");
}

unittest
{
    // comparison
    assert(BigInt(-3) < BigInt(-2));
    assert(BigInt(-3) < BigInt(0));
    assert(BigInt("007") == BigInt(7));
    assert(BigInt("-0") == BigInt(0));
    assert(BigInt("1000000000") > BigInt("999999999"));
    assert(BigInt("-1000000000") < BigInt("-999999999"));
    assert(BigInt(5).opCmp(BigInt(5)) == 0);
}

unittest
{
    // randomised comparison against machine integers
    import std.random : Mt19937, uniform;

    auto rng = Mt19937(42);
    foreach (i; 0 .. 5000)
    {
        const long x = uniform(-2_000_000_000_000L, 2_000_000_000_000L, rng);
        const long y = uniform(-3_000_000L, 3_000_000L, rng);
        const a = BigInt(x), b = BigInt(y);
        assert((a + b) == BigInt(x + y));
        assert((a - b) == BigInt(x - y));
        assert((a * b) == BigInt(x * y));
        assert(BigInt(x).opCmp(BigInt(y)) == (x < y ? -1 : (x > y ? 1 : 0)));
        if (y != 0)
        {
            assert((a / b) == BigInt(x / y));
            assert((a % b) == BigInt(x % y));
        }
    }
}

unittest
{
    // large identities: (a/b)*b + a%b == a, |r| < |b|, sign rules, powers vs repeated multiplication
    import std.random : Mt19937, uniform;

    auto rng = Mt19937(7);
    string randDigits(size_t n)
    {
        char[] s = new char[n];
        foreach (ref c; s)
            c = cast(char)('0' + uniform(0, 10, rng));
        if (n > 0 && uniform(0, 3, rng) == 0)
            s[0] = '9';
        return s.idup;
    }

    foreach (i; 0 .. 300)
    {
        auto a = BigInt((uniform(0, 2, rng) ? "-" : "") ~ randDigits(uniform(1, 400, rng)));
        auto b = BigInt((uniform(0, 2, rng) ? "-" : "") ~ randDigits(uniform(1, 200, rng)));
        if (b.isZero)
            continue;
        BigInt q, r;
        BigInt.divMod(a, b, q, r);
        assert(q * b + r == a);
        assert(r.abs < b.abs);
        assert(r.isZero || r.isNegative == a.isNegative);
        assert(BigInt.pow(a, 3) == a * a * a);
        assert((a + b) - b == a);
        assert((a - b) + b == a);
        assert(a * b == b * a);
        assert((a + b) * b == a * b + b * b);
        assert(BigInt.pow(b, 6) == (b * b) * (b * b) * (b * b));
    }
}

unittest
{
    // patterns of 9s and 10^n exercise the qhat correction paths
    auto a = BigInt("1" ~ "0".repeatStr(60));
    auto b = BigInt("9".repeatStr(27));
    BigInt q, r;
    BigInt.divMod(a, b, q, r);
    assert(q * b + r == a && r < b);
    auto c = BigInt("9".repeatStr(81));
    BigInt.divMod(c, b, q, r);
    assert(r.isZero);
    assert(q == BigInt("1" ~ "0".repeatStr(26) ~ "1" ~ "0".repeatStr(26) ~ "1"));
}

version (unittest)
{
    private string repeatStr(string s, size_t n) @safe pure
    {
        string r;
        foreach (_; 0 .. n)
            r ~= s;
        return r;
    }
}
