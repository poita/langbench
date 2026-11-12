/// Printing values the way the `sqlite3` shell does (SPEC Part 5).
module sqlitefile.render;

import core.stdc.stdio : snprintf;
import std.array : Appender;
import std.math : isFinite;
import sqlitefile.value;

@safe:

/// Output buffer type used by the engine.
alias OutBuf = Appender!(ubyte[]);

/// Formats a REAL like C's `%.15g`, with `.0` appended to a mantissa that has
/// no decimal point, and zero (either sign) printed as `0.0`.
string formatReal(double v) @trusted
{
    if (v == 0)
        return "0.0";
    char[64] buf;
    const n = snprintf(buf.ptr, buf.length, "%.15g", v);
    string s = buf[0 .. n].idup;
    if (!isFinite(v))
        return s;
    size_t e = s.length;
    foreach (k, c; s)
        if (c == 'e')
        {
            e = k;
            break;
        }
    bool hasPoint = false;
    foreach (c; s[0 .. e])
        if (c == '.')
            hasPoint = true;
    return hasPoint ? s : s[0 .. e] ~ ".0" ~ s[e .. $];
}

/// Appends the decimal form of `v` to `o`.
void appendInt(ref OutBuf o, long v)
{
    char[20] tmp;
    size_t p = tmp.length;
    ulong u = v < 0 ? 0UL - cast(ulong) v : cast(ulong) v;
    do
    {
        tmp[--p] = cast(char)('0' + u % 10);
        u /= 10;
    }
    while (u);
    if (v < 0)
        o.put(cast(ubyte) '-');
    foreach (c; tmp[p .. $])
        o.put(cast(ubyte) c);
}

/// Appends a string's bytes to `o`.
void appendText(ref OutBuf o, const(char)[] s) @trusted
{
    o.put(cast(const(ubyte)[]) s);
}

/// Appends `v` formatted as in the `sqlite3` shell with `-nullvalue NULL`.
void appendValue(ref OutBuf o, in Value v)
{
    static immutable hex = "0123456789ABCDEF";
    final switch (v.type)
    {
    case ValueType.null_:
        appendText(o, "NULL");
        break;
    case ValueType.integer:
        appendInt(o, v.i);
        break;
    case ValueType.real_:
        appendText(o, formatReal(v.r));
        break;
    case ValueType.text:
        o.put(v.bytes);
        break;
    case ValueType.blob:
        foreach (b; v.bytes)
        {
            o.put(cast(ubyte) hex[b >> 4]);
            o.put(cast(ubyte) hex[b & 15]);
        }
        break;
    }
}

/// Formats a single value as a `string`.
string formatValue(in Value v) @trusted
{
    OutBuf o;
    appendValue(o, v);
    return cast(string) o.data.idup;
}

unittest
{
    assert(formatReal(1.0) == "1.0");
    assert(formatReal(0.1) == "0.1");
    assert(formatReal(-3.25) == "-3.25");
    assert(formatReal(1.0 / 3) == "0.333333333333333");
    assert(formatReal(1e300) == "1.0e+300");
    assert(formatReal(2.5e-10) == "2.5e-10");
    assert(formatReal(1.5e16) == "1.5e+16");
    assert(formatReal(1e14) == "100000000000000.0");
    assert(formatReal(1e15) == "1.0e+15");
    assert(formatReal(0.0001) == "0.0001");
    assert(formatReal(1e-5) == "1.0e-05");
    assert(formatReal(0.0) == "0.0");
    assert(formatReal(-0.0) == "0.0");
    assert(formatReal(-1e-7) == "-1.0e-07");
}

unittest
{
    assert(formatValue(Value.makeNull()) == "NULL");
    assert(formatValue(Value.fromInt(-42)) == "-42");
    assert(formatValue(Value.fromInt(long.min)) == "-9223372036854775808");
    assert(formatValue(Value.fromInt(0)) == "0");
    assert(formatValue(Value.fromText("héllo")) == "héllo");
    assert(formatValue(Value.fromBlob([cast(ubyte) 0, 0x7f, 0xab])) == "007FAB");
    assert(formatValue(Value.fromBlob([])) == "");
    assert(formatValue(Value.fromReal(2.0)) == "2.0");
}
