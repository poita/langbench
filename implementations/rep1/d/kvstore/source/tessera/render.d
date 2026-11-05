/// Text rendering of values, keys and numbers for `results.txt`.
module tessera.render;

import tessera.bytes;
import tessera.value;

private static immutable hexDigits = "0123456789abcdef";

/// Append the decimal form of a signed integer.
void putDecimal(ref ByteBuffer o, long n) pure nothrow @safe
{
    if (n < 0)
    {
        o.put('-');
        putUnsigned(o, 0UL - cast(ulong) n);
    }
    else
        putUnsigned(o, cast(ulong) n);
}

/// Append the decimal form of an unsigned integer.
void putUnsigned(ref ByteBuffer o, ulong n) pure nothrow @safe
{
    char[20] tmp;
    size_t i = tmp.length;
    do
    {
        tmp[--i] = cast(char)('0' + n % 10);
        n /= 10;
    }
    while (n);
    o.putText(tmp[i .. $]);
}

/// Append a string in quoted, escaped form.
void renderString(ref ByteBuffer o, const(char)[] s) pure nothrow @safe
{
    o.put('"');
    foreach (char c; s)
    {
        switch (c)
        {
        case '"': o.putText("\\\""); break;
        case '\\': o.putText("\\\\"); break;
        case '\b': o.putText("\\b"); break;
        case '\t': o.putText("\\t"); break;
        case '\n': o.putText("\\n"); break;
        case '\f': o.putText("\\f"); break;
        case '\r': o.putText("\\r"); break;
        default:
            if (c < 0x20 || c == 0x7f)
            {
                o.putText("\\u00");
                o.put(hexDigits[(c >> 4) & 0xF]);
                o.put(hexDigits[c & 0xF]);
            }
            else
                o.put(cast(ubyte) c);
        }
    }
    o.put('"');
}

/// Append the canonical one-line rendering of a value.
void renderValue(ref ByteBuffer o, Value v) pure nothrow @safe
{
    final switch (v.kind)
    {
    case Kind.null_:
        o.putText("null");
        break;
    case Kind.boolean:
        o.putText(v.num ? "true" : "false");
        break;
    case Kind.integer:
        putDecimal(o, v.num);
        break;
    case Kind.string_:
        renderString(o, v.str);
        break;
    case Kind.list:
        o.put('[');
        foreach (i, ref e; v.items)
        {
            if (i)
                o.put(',');
            renderValue(o, e);
        }
        o.put(']');
        break;
    case Kind.object:
        o.put('{');
        foreach (i, ref e; v.items)
        {
            if (i)
                o.put(',');
            renderString(o, v.names[i]);
            o.put(':');
            renderValue(o, e);
        }
        o.put('}');
        break;
    }
}

/// The canonical rendering of a value as a string.
string renderToString(Value v) pure nothrow @safe
{
    ByteBuffer b;
    renderValue(b, v);
    return toStr(b.data);
}
