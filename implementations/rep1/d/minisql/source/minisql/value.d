/// The dynamically typed value model: NULL, INTEGER, TEXT and REAL.
module minisql.value;

import std.array : Appender;

/// The runtime type tag of a `Value`.
enum Kind : ubyte
{
    null_, /// SQL NULL
    integer, /// signed 64-bit integer
    text, /// UTF-8 text
    real_, /// a number with two decimals, produced only by `AVG`
}

/// A single SQL value.
///
/// Copying a value is O(1): text is a slice of immutable UTF-8 bytes that is
/// shared, never duplicated. A REAL is stored exactly as an integer number of
/// hundredths, because only `AVG` produces reals and it rounds to two decimals.
struct Value
{
    /// The type tag.
    Kind kind;
    /// The integer value, or the number of hundredths for a REAL.
    long num;
    /// The text, when `kind == Kind.text`.
    string str;

    /// The NULL value.
    static Value makeNull() pure nothrow @nogc @safe
    {
        return Value.init;
    }

    /// An INTEGER value.
    static Value makeInt(long v) pure nothrow @nogc @safe
    {
        Value r;
        r.kind = Kind.integer;
        r.num = v;
        return r;
    }

    /// A TEXT value (the string is shared, not copied).
    static Value makeText(string s) pure nothrow @nogc @safe
    {
        Value r;
        r.kind = Kind.text;
        r.str = s;
        return r;
    }

    /// A REAL value given as a number of hundredths (`450` is `4.50`).
    static Value makeReal(long hundredths) pure nothrow @nogc @safe
    {
        Value r;
        r.kind = Kind.real_;
        r.num = hundredths;
        return r;
    }

    /// True for NULL.
    bool isNull() const pure nothrow @nogc @safe
    {
        return kind == Kind.null_;
    }
}

private int rank(Kind k) pure nothrow @nogc @safe
{
    final switch (k)
    {
    case Kind.null_:
        return 0;
    case Kind.integer:
    case Kind.real_:
        return 1;
    case Kind.text:
        return 2;
    }
}

private int cmp3(long a, long b) pure nothrow @nogc @safe
{
    return a < b ? -1 : (a > b ? 1 : 0);
}

/// The total order used by comparisons, ORDER BY, GROUP BY, MIN and MAX.
///
/// NULL is smallest; every number is smaller than every text; numbers compare
/// by value; text compares bytewise (which is code point order for UTF-8).
/// Returns a negative number, zero or a positive number.
int compareValues(const Value a, const Value b) pure nothrow @nogc @safe
{
    immutable ra = rank(a.kind), rb = rank(b.kind);
    if (ra != rb)
        return ra < rb ? -1 : 1;
    final switch (a.kind)
    {
    case Kind.null_:
        return 0;
    case Kind.integer:
        if (b.kind == Kind.integer)
            return cmp3(a.num, b.num);
        return a.num < long.min / 100 ? -1 : (a.num > long.max / 100 ? 1 : cmp3(a.num * 100, b.num));
    case Kind.real_:
        if (b.kind == Kind.real_)
            return cmp3(a.num, b.num);
        return -compareValues(b, a);
    case Kind.text:
        return a.str < b.str ? -1 : (a.str == b.str ? 0 : 1);
    }
}

/// Value equality that includes the type tag: `1` and `'1'` differ, and NULL
/// equals NULL. Used for grouping and join keys.
bool sameValue(const Value a, const Value b) pure nothrow @nogc @safe
{
    if (a.kind != b.kind)
        return false;
    final switch (a.kind)
    {
    case Kind.null_:
        return true;
    case Kind.integer:
    case Kind.real_:
        return a.num == b.num;
    case Kind.text:
        return a.str == b.str;
    }
}

/// A 64-bit hash consistent with `sameValue`.
ulong hashValue(const Value v) pure nothrow @nogc @trusted
{
    final switch (v.kind)
    {
    case Kind.null_:
        return 0x9e3779b97f4a7c15UL;
    case Kind.integer:
    case Kind.real_:
        ulong x = cast(ulong) v.num + (v.kind == Kind.real_ ? 0x1234567UL : 0UL);
        x ^= x >> 33;
        x *= 0xff51afd7ed558ccdUL;
        x ^= x >> 33;
        x *= 0xc4ceb9fe1a85ec53UL;
        x ^= x >> 33;
        return x;
    case Kind.text:
        // FNV-1a over the bytes.
        ulong h = 0xcbf29ce484222325UL;
        foreach (c; v.str)
        {
            h ^= cast(ubyte) c;
            h *= 0x100000001b3UL;
        }
        return h;
    }
}

/// Appends the decimal text of `v` to `buf`; returns the used slice of `buf`.
/// `buf` must hold at least 20 characters.
char[] formatInteger(long v, return scope char[] buf) pure nothrow @nogc @safe
{
    size_t pos = buf.length;
    ulong u = v < 0 ? -cast(ulong) v : cast(ulong) v;
    do
    {
        buf[--pos] = cast(char)('0' + u % 10);
        u /= 10;
    }
    while (u != 0);
    if (v < 0)
        buf[--pos] = '-';
    return buf[pos .. $];
}

/// Appends the display form of a value to an output buffer: `NULL`, a decimal
/// integer, the raw text, or a REAL with exactly two decimals.
void appendValue(ref Appender!(char[]) sink, const Value v) pure @safe
{
    char[24] tmp = void;
    final switch (v.kind)
    {
    case Kind.null_:
        sink.put("NULL");
        break;
    case Kind.integer:
        sink.put(formatInteger(v.num, tmp[]));
        break;
    case Kind.text:
        sink.put(v.str);
        break;
    case Kind.real_:
        immutable neg = v.num < 0;
        immutable ulong u = neg ? -cast(ulong) v.num : cast(ulong) v.num;
        if (neg)
            sink.put('-');
        sink.put(formatInteger(cast(long)(u / 100), tmp[]));
        sink.put('.');
        sink.put(cast(char)('0' + (u % 100) / 10));
        sink.put(cast(char)('0' + u % 10));
        break;
    }
}

/// Renders a value the way the command-line tool prints it.
string toDisplay(const Value v) pure @safe
{
    Appender!(char[]) sink;
    appendValue(sink, v);
    return sink[].idup;
}
