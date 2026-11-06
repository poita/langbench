/// SQL values and the SQLite ordering of them.
module sqlitefile.value;

import core.stdc.string : memcmp;

@safe:

/// The five SQLite storage classes.
enum ValueKind : ubyte
{
    null_,
    integer,
    real_,
    text,
    blob,
}

/// A single SQL value.
///
/// TEXT and BLOB values are *views*: `bytes` usually points straight into the
/// database image, so a `Value` is only valid as long as that memory is.
struct Value
{
    ValueKind kind;
    union
    {
        long i;
        double r;
    }
    const(ubyte)[] bytes;

    /// The NULL value.
    static Value makeNull() pure nothrow @nogc
    {
        return Value.init;
    }

    /// An INTEGER value.
    static Value makeInt(long v) pure nothrow @nogc
    {
        Value x;
        x.kind = ValueKind.integer;
        x.i = v;
        return x;
    }

    /// A REAL value.
    static Value makeReal(double v) pure nothrow @nogc
    {
        Value x;
        x.kind = ValueKind.real_;
        x.r = v;
        return x;
    }

    /// A TEXT value (UTF-8 bytes).
    static Value makeText(const(ubyte)[] b) pure nothrow @nogc
    {
        Value x;
        x.kind = ValueKind.text;
        x.bytes = b;
        return x;
    }

    /// A TEXT value from a D string.
    static Value makeText(string s) pure nothrow @nogc @trusted
    {
        return makeText(cast(const(ubyte)[]) s);
    }

    /// A BLOB value.
    static Value makeBlob(const(ubyte)[] b) pure nothrow @nogc
    {
        Value x;
        x.kind = ValueKind.blob;
        x.bytes = b;
        return x;
    }

    bool isNull() const pure nothrow @nogc
    {
        return kind == ValueKind.null_;
    }

    bool isNumber() const pure nothrow @nogc
    {
        return kind == ValueKind.integer || kind == ValueKind.real_;
    }
}

/// Three-way unsigned bytewise comparison (BINARY collation); shorter wins on a common prefix.
int compareBytes(const(ubyte)[] a, const(ubyte)[] b) pure nothrow @nogc @trusted
{
    immutable n = a.length < b.length ? a.length : b.length;
    immutable c = n ? memcmp(a.ptr, b.ptr, n) : 0;
    if (c != 0)
        return c < 0 ? -1 : 1;
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

private int rank(ValueKind k) pure nothrow @nogc
{
    final switch (k)
    {
    case ValueKind.null_:
        return 0;
    case ValueKind.integer:
    case ValueKind.real_:
        return 1;
    case ValueKind.text:
        return 2;
    case ValueKind.blob:
        return 3;
    }
}

/// Three-way comparison implementing SQLite's ordering:
/// NULL < numbers < TEXT < BLOB. Integers compare exactly, mixed
/// integer/real comparisons widen the integer to a double.
int compareValues(in Value a, in Value b) pure nothrow @nogc
{
    immutable ra = rank(a.kind), rb = rank(b.kind);
    if (ra != rb)
        return ra < rb ? -1 : 1;
    switch (ra)
    {
    case 0:
        return 0;
    case 1:
        if (a.kind == ValueKind.integer && b.kind == ValueKind.integer)
            return a.i < b.i ? -1 : (a.i > b.i ? 1 : 0);
        immutable x = a.kind == ValueKind.integer ? cast(double) a.i : a.r;
        immutable y = b.kind == ValueKind.integer ? cast(double) b.i : b.r;
        return x < y ? -1 : (x > y ? 1 : 0);
    default:
        return compareBytes(a.bytes, b.bytes);
    }
}
