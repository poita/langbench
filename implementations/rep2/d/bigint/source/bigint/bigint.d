/**
 * Signed arbitrary-precision integers.
 *
 * $(LREF BigInt) stores a sign and a magnitude (see $(MREF bigint, natural)).
 * It is a value type with the usual operators:
 * `+ - * / % ^^`, unary `-`, comparison and equality, and converts to and
 * from decimal text in linear time.
 *
 * Multiplication is schoolbook O(n*m); division is Knuth's Algorithm D;
 * exponentiation uses repeated squaring.
 *
 * Division and remainder truncate toward zero (C semantics): the remainder
 * is zero or has the sign of the dividend.
 */
module bigint.bigint;

import bigint.decimal : appendDigits, parseDigits, ParseException;
import bigint.natural;

/// Thrown by division, remainder and negative exponents.
class BigIntException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// A signed arbitrary-precision integer.
struct BigInt
{
    private bool negative;  // never true for zero
    private Natural mag;    // normalised magnitude

    /// Constructs from a machine integer.
    this(long v) pure nothrow @safe
    {
        negative = v < 0;
        // -(v + 1) + 1 avoids overflow for long.min
        immutable ulong m = v < 0 ? cast(ulong)(-(v + 1)) + 1 : cast(ulong) v;
        mag = fromUlong(m);
    }

    /**
     * Constructs from decimal text: an optional `-`, then one or more digits.
     * Leading zeros and `-0` are accepted.
     *
     * Throws: $(REF ParseException, bigint, decimal) on malformed text.
     */
    this(const(char)[] text) pure @safe
    {
        bool neg = false;
        if (text.length > 0 && text[0] == '-')
        {
            neg = true;
            text = text[1 .. $];
        }
        mag = parseDigits(text);
        negative = neg && mag.length != 0;
    }

    private this(bool negative, Natural mag) pure nothrow @safe
    {
        this.mag = mag;
        this.negative = negative && mag.length != 0;
    }

    /// True if the value is zero.
    @property bool isZero() const pure nothrow @nogc @safe
    {
        return mag.length == 0;
    }

    /// True if the value is strictly negative.
    @property bool isNegative() const pure nothrow @nogc @safe
    {
        return negative;
    }

    /// -1, 0 or 1 according to the sign of the value.
    @property int sign() const pure nothrow @nogc @safe
    {
        return mag.length == 0 ? 0 : (negative ? -1 : 1);
    }

    /// Whether the value is odd.
    @property bool isOdd() const pure nothrow @nogc @safe
    {
        // The radix is even, so the parity is the parity of the lowest limb.
        return mag.length != 0 && (mag[0] & 1) != 0;
    }

    /// Absolute value.
    BigInt abs() const pure nothrow @safe
    {
        return BigInt(false, mag.dup);
    }

    /// Converts to `long`; returns false if the value is out of range.
    bool toLong(out long result) const pure nothrow @nogc @safe
    {
        ulong m;
        result = 0;
        if (!toUlong(mag, m))
            return false;
        if (negative)
        {
            if (m > cast(ulong) long.max + 1)
                return false;
            result = cast(long)(0 - m);
        }
        else
        {
            if (m > long.max)
                return false;
            result = cast(long) m;
        }
        return true;
    }

    /// Decimal representation in canonical form (no leading zeros, never "-0").
    string toString() const pure nothrow @safe
    {
        char[] buf;
        if (negative)
            buf ~= '-';
        buf = appendDigits(buf, mag);
        return (() @trusted => cast(string) buf)();
    }

    /// Appends the canonical decimal representation to `buf`.
    char[] appendTo(char[] buf) const pure nothrow @safe
    {
        if (negative)
            buf ~= '-';
        return appendDigits(buf, mag);
    }

    /// Unary minus.
    BigInt opUnary(string op : "-")() const pure nothrow @safe
    {
        return BigInt(!negative, mag.dup);
    }

    /// `+`, `-`, `*`, `/` (truncating) and `%` (sign of the dividend).
    BigInt opBinary(string op)(const BigInt rhs) const pure @safe
        if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%")
    {
        static if (op == "+")
            return addSigned(this, rhs, false);
        else static if (op == "-")
            return addSigned(this, rhs, true);
        else static if (op == "*")
            return BigInt(negative != rhs.negative, mul(mag, rhs.mag));
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

    /// Exponentiation `this ^^ exponent` (`x ^^ 0 == 1`, including `0 ^^ 0`).
    BigInt opBinary(string op : "^^")(ulong exponent) const pure nothrow @safe
    {
        return BigInt(negative && (exponent & 1) != 0, natural.pow(mag, exponent));
    }

    /// Exponentiation with a `BigInt` exponent.
    ///
    /// Throws: $(LREF BigIntException) if the exponent is negative, or if it
    /// is too large for the result to be representable (only possible when
    /// the base has magnitude two or more).
    BigInt opBinary(string op : "^^")(const BigInt exponent) const pure @safe
    {
        if (exponent.negative)
            throw new BigIntException("negative exponent");
        ulong e;
        if (toUlong(exponent.mag, e))
            return this ^^ e;
        // Exponent does not fit a machine word: only bases 0, 1, -1 are computable.
        if (mag.length == 0)
            return BigInt(0);
        if (mag.length == 1 && mag[0] == 1)
            return BigInt(negative && exponent.isOdd, mag.dup);
        throw new BigIntException("exponent too large");
    }

    /// Compound assignment forms of the binary operators.
    ref BigInt opOpAssign(string op, T)(const T rhs) pure @safe
    {
        this = opBinary!op(rhs);
        return this;
    }

    /// Three-way comparison by numeric value.
    int opCmp(const BigInt rhs) const pure nothrow @nogc @safe
    {
        if (negative != rhs.negative)
            return negative ? -1 : 1;
        immutable c = compare(mag, rhs.mag);
        return negative ? -c : c;
    }

    /// Equality by numeric value.
    bool opEquals(const BigInt rhs) const pure nothrow @nogc @safe
    {
        return negative == rhs.negative && mag == rhs.mag;
    }

    /// Hash consistent with `opEquals`.
    size_t toHash() const nothrow @safe
    {
        size_t h = negative ? 1 : 0;
        foreach (limb; mag)
            h = h * 1_000_003 + limb;
        return h;
    }
}

private alias natural = bigint.natural;

// a + b, or a - b when `subtract` is set.
private BigInt addSigned(const BigInt a, const BigInt b, bool subtract) pure nothrow @safe
{
    immutable bneg = b.negative != subtract && !b.isZero;
    if (a.negative == bneg)
        return BigInt(a.negative, add(a.mag, b.mag));
    immutable c = compare(a.mag, b.mag);
    if (c == 0)
        return BigInt(0);
    if (c > 0)
        return BigInt(a.negative, sub(a.mag, b.mag));
    return BigInt(bneg, sub(b.mag, a.mag));
}

/**
 * Truncating division with remainder, computed together.
 *
 * `a == q * b + r`, `|r| < |b|`, and `r` is zero or has the sign of `a`.
 *
 * Throws: $(LREF BigIntException) if `b` is zero.
 */
void divMod(const BigInt a, const BigInt b, out BigInt q, out BigInt r) pure @safe
{
    if (b.isZero)
        throw new BigIntException("division by zero");
    Natural qm, rm;
    bigint.natural.divMod(a.mag, b.mag, qm, rm);
    q = BigInt(a.negative != b.negative, qm);
    r = BigInt(a.negative, rm);
}

/// Exponentiation as a function: `pow(a, n) == a ^^ n`.
BigInt pow(const BigInt base, ulong exponent) pure nothrow @safe
{
    return base ^^ exponent;
}

///
@("bigint: usage example")
unittest
{
    auto a = BigInt("-123456789012345678901234567890");
    auto b = BigInt("987654321098765432109876543210");
    assert((a * b).toString == "-121932631137021795226185032733622923332237463801111263526900");
    assert((BigInt(-7) / BigInt(2)).toString == "-3");
    assert((BigInt(-7) % BigInt(2)).toString == "-1");
    assert((BigInt(2) ^^ 100).toString == "1267650600228229401496703205376");
    assert(BigInt("-0") == BigInt(0));
    assert(BigInt("007") > BigInt("-7"));
}

@("bigint: construction and canonical printing")
unittest
{
    assert(BigInt("-000").toString == "0");
    assert(BigInt("-0001230").toString == "-1230");
    assert(BigInt(long.min).toString == "-9223372036854775808");
    assert(BigInt(long.max).toString == "9223372036854775807");
    assert(BigInt(0).toString == "0");
    assert(!BigInt("-0").isNegative);
    assert(BigInt("-5").sign == -1 && BigInt("0").sign == 0 && BigInt("5").sign == 1);
    long l;
    assert(BigInt(long.min).toLong(l) && l == long.min);
    assert(!BigInt("9223372036854775808").toLong(l));
    assert(BigInt("-9223372036854775808").toLong(l) && l == long.min);
}

@("bigint: addition and subtraction signs")
unittest
{
    foreach (x; -20 .. 21)
        foreach (y; -20 .. 21)
        {
            assert(BigInt(x) + BigInt(y) == BigInt(x + y));
            assert(BigInt(x) - BigInt(y) == BigInt(x - y));
            assert(BigInt(x) * BigInt(y) == BigInt(x * y));
            assert((BigInt(x) + BigInt(y)).toString == itos(x + y));
        }
    assert((BigInt("-0") + BigInt("0")).toString == "0");
    assert((BigInt("999999999999999999999999999999") + BigInt(1)).toString
            == "1000000000000000000000000000000");
    assert((BigInt("1000000000000000000000000000000") - BigInt(1)).toString
            == "999999999999999999999999999999");
}

version (unittest)
{
    private string itos(long v)
    {
        import std.conv : to;

        return v.to!string;
    }
}

@("bigint: division and remainder follow C semantics")
unittest
{
    foreach (x; -30 .. 31)
        foreach (y; -30 .. 31)
        {
            if (y == 0)
                continue;
            assert(BigInt(x) / BigInt(y) == BigInt(x / y));
            assert(BigInt(x) % BigInt(y) == BigInt(x % y));
        }
    assert((BigInt(-1) / BigInt(2)).toString == "0");
    assert((BigInt(-7) % BigInt(7)).toString == "0");
}

@("bigint: division by zero throws")
unittest
{
    import std.exception : assertThrown;

    assertThrown!BigIntException(BigInt(1) / BigInt(0));
    assertThrown!BigIntException(BigInt(0) % BigInt(0));
    assertThrown!BigIntException(BigInt(0) % BigInt("-000"));
}

@("bigint: large division round trip")
unittest
{
    import std.array : replicate;

    auto a = BigInt("7".replicate(5000) ~ "123456789");
    auto b = BigInt("9".replicate(2500) ~ "5");
    BigInt q, r;
    divMod(a, b, q, r);
    assert(q * b + r == a);
    assert(r < b && !r.isNegative);
    divMod(-a, b, q, r);
    assert(q * b + r == -a);
    assert(r.sign <= 0 && r.abs < b);
}

@("bigint: powers")
unittest
{
    import std.exception : assertThrown;

    assert((BigInt(0) ^^ 0).toString == "1");
    assert((BigInt(0) ^^ 5).toString == "0");
    assert((BigInt(-2) ^^ 3).toString == "-8");
    assert((BigInt(-2) ^^ 2).toString == "4");
    assert((BigInt(-1) ^^ 999).toString == "-1");
    assert((BigInt(10) ^^ 30).toString == "1" ~ "000000000000000000000000000000");
    assert((BigInt(5) ^^ BigInt("-0")).toString == "1");
    assert((BigInt(-0) ^^ BigInt("-00")).toString == "1");
    assertThrown!BigIntException(BigInt(2) ^^ BigInt(-1));
    // exponents beyond a machine word are fine for 0, 1, -1
    assert((BigInt(-1) ^^ BigInt("100000000000000000000000000000000000001")).toString == "-1");
    assert((BigInt(1) ^^ BigInt("100000000000000000000000000000000000000")).toString == "1");
    assert((BigInt(0) ^^ BigInt("100000000000000000000000000000000000000")).toString == "0");
    assertThrown!BigIntException(BigInt(2) ^^ BigInt("100000000000000000000000000000000000000"));
}

@("bigint: comparison")
unittest
{
    assert(BigInt("007") == BigInt(7));
    assert(BigInt("-0") == BigInt("0"));
    assert(BigInt(-3) < BigInt(-2));
    assert(BigInt("-100000000000000000000") < BigInt("-99999999999999999999"));
    assert(BigInt("100000000000000000000") > BigInt("99999999999999999999"));
    assert(BigInt(5).opCmp(BigInt(5)) == 0);
}

@("bigint: compound assignment")
unittest
{
    auto x = BigInt(10);
    x += BigInt(5);
    x *= BigInt(2);
    x -= BigInt(1);
    x /= BigInt(3);
    x %= BigInt(7);
    assert(x == BigInt(2));
}
