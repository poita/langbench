/// The SQLite value model: storage classes and the total ordering of Part 3.
module sqlitefile.value;

import std.algorithm.comparison : cmp;

@safe:

/// The five SQLite storage classes.
enum ValueType : ubyte
{
    null_,
    integer,
    real_,
    text,
    blob,
}

/// A single SQLite value.
///
/// TEXT and BLOB values hold a slice (`bytes`); for values read from a
/// database that slice points into the loaded file, so no copy is made.
struct Value
{
    ValueType type;
    union
    {
        long i; /// valid when `type == integer`
        double r; /// valid when `type == real`
    }

    const(ubyte)[] bytes; /// valid when `type` is `text` or `blob`

    /// The NULL value.
    static Value makeNull() pure nothrow @nogc
    {
        return Value.init;
    }

    /// An INTEGER value.
    static Value fromInt(long v) pure nothrow @nogc
    {
        Value x;
        x.type = ValueType.integer;
        x.i = v;
        return x;
    }

    /// A REAL value.
    static Value fromReal(double v) pure nothrow @nogc
    {
        Value x;
        x.type = ValueType.real_;
        x.r = v;
        return x;
    }

    /// A TEXT value (UTF-8 bytes).
    static Value fromText(const(ubyte)[] v) pure nothrow @nogc
    {
        Value x;
        x.type = ValueType.text;
        x.bytes = v;
        return x;
    }

    /// ditto
    static Value fromText(string v) pure nothrow @nogc @trusted
    {
        return fromText(cast(const(ubyte)[]) v);
    }

    /// A BLOB value.
    static Value fromBlob(const(ubyte)[] v) pure nothrow @nogc
    {
        Value x;
        x.type = ValueType.blob;
        x.bytes = v;
        return x;
    }

    /// True for NULL.
    bool isNull() const pure nothrow @nogc
    {
        return type == ValueType.null_;
    }

    /// True for INTEGER and REAL.
    bool isNumber() const pure nothrow @nogc
    {
        return type == ValueType.integer || type == ValueType.real_;
    }

    /// The TEXT payload as a `string` (copying it).
    string toStringCopy() const pure @trusted
    {
        return cast(string) bytes.idup;
    }
}

private int classRank(ValueType t) pure nothrow @nogc
{
    final switch (t)
    {
    case ValueType.null_:
        return 0;
    case ValueType.integer:
    case ValueType.real_:
        return 1;
    case ValueType.text:
        return 2;
    case ValueType.blob:
        return 3;
    }
}

private double asDouble(in Value v) pure nothrow @nogc
{
    return v.type == ValueType.integer ? cast(double) v.i : v.r;
}

/// Three-way comparison following SPEC Part 3: NULL < numbers < TEXT < BLOB;
/// two INTEGERs compare exactly, mixed numbers as doubles, TEXT and BLOB by
/// unsigned bytes. Returns a negative number, zero or a positive number.
int compare(in Value a, in Value b) pure nothrow
{
    const ra = classRank(a.type), rb = classRank(b.type);
    if (ra != rb)
        return ra < rb ? -1 : 1;
    final switch (a.type)
    {
    case ValueType.null_:
        return 0;
    case ValueType.integer:
    case ValueType.real_:
        if (a.type == ValueType.integer && b.type == ValueType.integer)
            return a.i < b.i ? -1 : (a.i > b.i ? 1 : 0);
        const x = asDouble(a), y = asDouble(b);
        return x < y ? -1 : (x > y ? 1 : 0);
    case ValueType.text:
    case ValueType.blob:
        return cmp(a.bytes, b.bytes);
    }
}

unittest
{
    const n = Value.makeNull();
    const i1 = Value.fromInt(1);
    const r1 = Value.fromReal(1.0);
    const t = Value.fromText("a");
    const b = Value.fromBlob([cast(ubyte) 0]);
    assert(compare(n, n) == 0);
    assert(compare(n, i1) < 0);
    assert(compare(i1, t) < 0);
    assert(compare(t, b) < 0);
    assert(compare(b, n) > 0);
    assert(compare(i1, r1) == 0);
    assert(compare(Value.fromInt(2), r1) > 0);
    assert(compare(Value.fromReal(0.5), i1) < 0);
}

unittest
{
    // INTEGERs are compared exactly past 2^53.
    assert(compare(Value.fromInt(long.max), Value.fromInt(long.max - 1)) > 0);
    assert(compare(Value.fromInt(long.min), Value.fromInt(long.max)) < 0);
}

unittest
{
    // TEXT: unsigned bytes, prefix is smaller.
    assert(compare(Value.fromText("ab"), Value.fromText("abc")) < 0);
    assert(compare(Value.fromText("b"), Value.fromText("abc")) > 0);
    assert(compare(Value.fromText("é"), Value.fromText("z")) > 0);
    assert(compare(Value.fromBlob([]), Value.fromBlob([cast(ubyte) 0])) < 0);
}
