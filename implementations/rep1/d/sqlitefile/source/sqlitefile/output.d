/// Formatting of values the way the `sqlite3` shell prints them, written
/// straight into a reusable byte buffer.
module sqlitefile.output;

import core.stdc.stdio : snprintf;
import sqlitefile.value;

@safe:

/// A growable byte buffer used to build one query's output.
struct OutBuf
{
    private ubyte[] buf;
    private size_t len;

    /// Appends one byte.
    void put(ubyte b) pure nothrow
    {
        reserve(1);
        buf[len++] = b;
    }

    /// Appends a byte slice.
    void put(const(ubyte)[] s) pure nothrow
    {
        reserve(s.length);
        buf[len .. len + s.length] = s[];
        len += s.length;
    }

    /// Appends a string's UTF-8 bytes.
    void put(string s) pure nothrow @trusted
    {
        put(cast(const(ubyte)[]) s);
    }

    /// The bytes written so far.
    const(ubyte)[] data() const pure nothrow @nogc
    {
        return buf[0 .. len];
    }

    /// Discards the contents (keeping the allocation).
    void clear() pure nothrow @nogc
    {
        len = 0;
    }

    size_t length() const pure nothrow @nogc
    {
        return len;
    }

    private void reserve(size_t n) pure nothrow
    {
        if (len + n <= buf.length)
            return;
        size_t cap = buf.length * 2;
        if (cap < len + n)
            cap = len + n;
        if (cap < 256)
            cap = 256;
        buf.length = cap;
    }
}

/// Appends `v` in decimal.
void appendInteger(ref OutBuf o, long v) pure nothrow
{
    char[20] tmp = void;
    size_t p = tmp.length;
    ulong u = v < 0 ? 0UL - cast(ulong) v : cast(ulong) v;
    do
    {
        tmp[--p] = cast(char)('0' + u % 10);
        u /= 10;
    }
    while (u != 0);
    if (v < 0)
        o.put(cast(ubyte) '-');
    foreach (c; tmp[p .. $])
        o.put(cast(ubyte) c);
}

/// Appends a REAL the way the spec's Part 5 requires: `%.15g`, with `.0`
/// added to a mantissa that has no point, and `-0.0` printed as `0.0`.
void appendReal(ref OutBuf o, double v) nothrow @trusted
{
    if (v == 0)
    {
        o.put("0.0");
        return;
    }
    char[64] tmp = void;
    immutable n = snprintf(tmp.ptr, tmp.length, "%.15g", v);
    size_t e = n; // index of the exponent marker, or the end
    bool hasPoint = false;
    foreach (i; 0 .. cast(size_t) n)
    {
        immutable c = tmp[i];
        if (c == '.')
            hasPoint = true;
        else if (c == 'e')
        {
            e = i;
            break;
        }
    }
    foreach (c; tmp[0 .. e])
        o.put(cast(ubyte) c);
    if (!hasPoint)
        o.put(".0");
    foreach (c; tmp[e .. n])
        o.put(cast(ubyte) c);
}

/// Formats a REAL as a string (see `appendReal`).
string formatReal(double v) @trusted
{
    OutBuf o;
    appendReal(o, v);
    return cast(string) o.data.idup;
}

private immutable string hexDigits = "0123456789ABCDEF";

/// Appends `v` as the shell prints it: NULL as `NULL`, blobs as uppercase hex.
void appendValue(ref OutBuf o, in Value v) nothrow
{
    final switch (v.kind)
    {
    case ValueKind.null_:
        o.put("NULL");
        break;
    case ValueKind.integer:
        appendInteger(o, v.i);
        break;
    case ValueKind.real_:
        appendReal(o, v.r);
        break;
    case ValueKind.text:
        o.put(v.bytes);
        break;
    case ValueKind.blob:
        foreach (b; v.bytes)
        {
            o.put(cast(ubyte) hexDigits[b >> 4]);
            o.put(cast(ubyte) hexDigits[b & 15]);
        }
        break;
    }
}
