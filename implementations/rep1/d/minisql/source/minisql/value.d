/**
 * Dynamically typed SQL values and the total order used to compare them.
 */
module minisql.value;

import core.stdc.string : memcmp;

/// The kind of a $(LREF Value).
enum ValueKind : ubyte
{
    null_,    /// SQL NULL
    integer,  /// signed 64-bit integer
    text,     /// UTF-8 text
    real_,    /// a number with two decimals; only produced by `AVG`
}

/**
 * A single SQL value.
 *
 * `REAL` values are stored as a whole number of hundredths (the only way the
 * dialect produces them is `AVG`, which rounds to two decimals).
 */
struct Value
{
    ValueKind kind;
    /// The integer, or the number of hundredths of a REAL.
    long num;
    /// The characters of a TEXT value.
    string str;

    /// The NULL value.
    static Value null_() @safe pure nothrow @nogc
    {
        return Value.init;
    }

    /// An INTEGER value.
    static Value integer(long v) @safe pure nothrow @nogc
    {
        Value r;
        r.kind = ValueKind.integer;
        r.num = v;
        return r;
    }

    /// A TEXT value.
    static Value text(string s) @safe pure nothrow @nogc
    {
        Value r;
        r.kind = ValueKind.text;
        r.str = s;
        return r;
    }

    /// A REAL value equal to `hundredths / 100`.
    static Value real_(long hundredths) @safe pure nothrow @nogc
    {
        Value r;
        r.kind = ValueKind.real_;
        r.num = hundredths;
        return r;
    }

    /// True for NULL.
    bool isNull() const @safe pure nothrow @nogc
    {
        return kind == ValueKind.null_;
    }

    /// True for INTEGER and REAL.
    bool isNumber() const @safe pure nothrow @nogc
    {
        return kind == ValueKind.integer || kind == ValueKind.real_;
    }
}

/// Three-valued truth: `unknown` is what NULL means in boolean context.
enum Truth : ubyte
{
    false_,
    true_,
    unknown,
}

/// Interprets `v` as a truth value (NULL is unknown, zero is false).
Truth truthOf(in Value v) @safe pure nothrow @nogc
{
    final switch (v.kind)
    {
    case ValueKind.null_:
        return Truth.unknown;
    case ValueKind.integer:
    case ValueKind.real_:
        return v.num != 0 ? Truth.true_ : Truth.false_;
    case ValueKind.text:
        return Truth.false_;
    }
}

/// The INTEGER 1 / 0 / NULL for a truth value.
Value valueOf(Truth t) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case Truth.true_:
        return Value.integer(1);
    case Truth.false_:
        return Value.integer(0);
    case Truth.unknown:
        return Value.null_;
    }
}

private int rank(in Value v) @safe pure nothrow @nogc
{
    final switch (v.kind)
    {
    case ValueKind.null_:
        return 0;
    case ValueKind.integer:
    case ValueKind.real_:
        return 1;
    case ValueKind.text:
        return 2;
    }
}

private int cmpLong(long a, long b) @safe pure nothrow @nogc
{
    return a < b ? -1 : (a > b ? 1 : 0);
}

private int cmpNumber(in Value a, in Value b) @safe pure nothrow @nogc
{
    if (a.kind == b.kind)
        return cmpLong(a.num, b.num);
    // One INTEGER and one REAL: compare in hundredths, guarding overflow.
    enum limit = long.max / 100;
    if (a.kind == ValueKind.integer)
    {
        if (a.num > limit)
            return 1;
        if (a.num < -limit)
            return -1;
        return cmpLong(a.num * 100, b.num);
    }
    return -cmpNumber(b, a);
}

/**
 * The total order of the dialect: NULL < numbers < text; numbers compare by
 * value, text by code point (equivalently, bytewise as UTF-8).
 *
 * Returns: a negative number, zero or a positive number.
 */
int compareValues(in Value a, in Value b) @trusted pure nothrow @nogc
{
    immutable ra = rank(a), rb = rank(b);
    if (ra != rb)
        return ra < rb ? -1 : 1;
    if (ra == 0)
        return 0;
    if (ra == 1)
        return cmpNumber(a, b);
    immutable n = a.str.length < b.str.length ? a.str.length : b.str.length;
    immutable c = n == 0 ? 0 : memcmp(a.str.ptr, b.str.ptr, n);
    if (c != 0)
        return c < 0 ? -1 : 1;
    return cmpLong(a.str.length, b.str.length);
}

/// Value equality under the total order (NULL equals NULL here).
bool sameValue(in Value a, in Value b) @safe pure nothrow @nogc
{
    return compareValues(a, b) == 0;
}

/// Appends the decimal form of `v` to `sink`.
void putInteger(Sink)(ref Sink sink, long v)
{
    char[20] buf;
    size_t i = buf.length;
    // Work with the negative magnitude so long.min is handled.
    long n = v > 0 ? -v : v;
    do
    {
        buf[--i] = cast(char)('0' - n % 10);
        n /= 10;
    }
    while (n != 0);
    if (v < 0)
        buf[--i] = '-';
    sink.put(buf[i .. $]);
}

/// Appends `h` hundredths as a number with exactly two decimals.
void putHundredths(Sink)(ref Sink sink, long h)
{
    if (h < 0)
        sink.put("-");
    // Magnitude as unsigned, safe for long.min.
    ulong m = h < 0 ? -cast(ulong) h : cast(ulong) h;
    putInteger(sink, cast(long)(m / 100));
    sink.put(".");
    immutable f = cast(uint)(m % 100);
    char[2] d = [cast(char)('0' + f / 10), cast(char)('0' + f % 10)];
    sink.put(d[]);
}

/// Appends the output form of `v` (as printed by a SELECT) to `sink`.
void formatValue(Sink)(ref Sink sink, in Value v)
{
    final switch (v.kind)
    {
    case ValueKind.null_:
        sink.put("NULL");
        break;
    case ValueKind.integer:
        putInteger(sink, v.num);
        break;
    case ValueKind.text:
        sink.put(v.str);
        break;
    case ValueKind.real_:
        putHundredths(sink, v.num);
        break;
    }
}

/// The output form of `v` as a string.
string toText(in Value v) @safe pure
{
    import std.array : appender;

    auto app = appender!string;
    formatValue(app, v);
    return app[];
}

@("compareValues orders NULL < numbers < text")
unittest
{
    assert(compareValues(Value.null_, Value.integer(-5)) < 0);
    assert(compareValues(Value.integer(100), Value.text("0")) < 0);
    assert(compareValues(Value.text("B"), Value.text("a")) < 0);
    assert(compareValues(Value.text(""), Value.text("a")) < 0);
    assert(compareValues(Value.text("ab"), Value.text("b")) < 0);
    assert(compareValues(Value.text("ab"), Value.text("ab")) == 0);
    assert(compareValues(Value.null_, Value.null_) == 0);
    assert(compareValues(Value.integer(2), Value.real_(200)) == 0);
    assert(compareValues(Value.integer(2), Value.real_(201)) < 0);
    assert(compareValues(Value.real_(-113), Value.integer(-1)) < 0);
}

@("values are formatted the way SELECT prints them")
unittest
{
    assert(toText(Value.null_) == "NULL");
    assert(toText(Value.integer(-42)) == "-42");
    assert(toText(Value.integer(0)) == "0");
    assert(toText(Value.integer(long.min)) == "-9223372036854775808");
    assert(toText(Value.text("hi")) == "hi");
    assert(toText(Value.real_(450)) == "4.50");
    assert(toText(Value.real_(-113)) == "-1.13");
    assert(toText(Value.real_(0)) == "0.00");
    assert(toText(Value.real_(5)) == "0.05");
}

@("truthOf interprets values in boolean context")
unittest
{
    assert(truthOf(Value.null_) == Truth.unknown);
    assert(truthOf(Value.integer(0)) == Truth.false_);
    assert(truthOf(Value.integer(-3)) == Truth.true_);
    assert(truthOf(Value.real_(0)) == Truth.false_);
    assert(truthOf(Value.real_(1)) == Truth.true_);
}
