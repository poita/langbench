/**
 * Byte-string helpers. Everything here works on bytes and never decodes
 * UTF-8, so invalid sequences are harmless.
 */
module kiln.text;

import std.array : Appender, appender;

/// Index of the first occurrence of `needle` in `hay` at or after `from`, or -1.
ptrdiff_t findBytes(const(char)[] hay, const(char)[] needle, size_t from = 0) @safe pure nothrow @nogc
{
    if (needle.length == 0)
        return from <= hay.length ? cast(ptrdiff_t) from : -1;
    if (needle.length > hay.length)
        return -1;
    immutable last = hay.length - needle.length;
    immutable first = needle[0];
    for (size_t i = from; i <= last; i++)
    {
        if (hay[i] != first)
            continue;
        if (hay[i .. i + needle.length] == needle)
            return cast(ptrdiff_t) i;
    }
    return -1;
}

/// Whether `s` contains `needle` (an empty needle is always contained).
bool containsBytes(const(char)[] s, const(char)[] needle) @safe pure nothrow @nogc
{
    return findBytes(s, needle) >= 0;
}

/// Byte-prefix test.
bool startsWithBytes(const(char)[] s, const(char)[] p) @safe pure nothrow @nogc
{
    return s.length >= p.length && s[0 .. p.length] == p;
}

/// Byte-suffix test.
bool endsWithBytes(const(char)[] s, const(char)[] p) @safe pure nothrow @nogc
{
    return s.length >= p.length && s[$ - p.length .. $] == p;
}

/// Left-to-right non-overlapping replacement. `from` must be non-empty.
string replaceAll(string s, const(char)[] from, const(char)[] to) @safe pure
in (from.length > 0)
{
    auto pos = findBytes(s, from);
    if (pos < 0)
        return s;
    auto app = appender!(char[]);
    app.reserve(s.length);
    size_t cur = 0;
    while (pos >= 0)
    {
        app.put(s[cur .. pos]);
        app.put(to);
        cur = pos + from.length;
        pos = findBytes(s, from, cur);
    }
    app.put(s[cur .. $]);
    return (() @trusted => cast(string) app.data)();
}

/**
 * The lines of a byte string: split at every 0x0A, dropping the final empty
 * piece. Each line is a view into `c`.
 */
string[] splitLines(string c) @safe pure nothrow
{
    string[] r;
    if (c.length == 0)
        return r;
    size_t start = 0;
    foreach (i; 0 .. c.length)
        if (c[i] == '\n')
        {
            r ~= c[start .. i];
            start = i + 1;
        }
    if (start < c.length)
        r ~= c[start .. $];
    return r;
}

/// Number of lines as defined by `splitLines`, without allocating.
size_t countLines(const(char)[] c) @safe pure nothrow @nogc
{
    if (c.length == 0)
        return 0;
    size_t n = 0;
    foreach (b; c)
        if (b == '\n')
            n++;
    if (c[$ - 1] != '\n')
        n++;
    return n;
}

/// Each line followed by one 0x0A.
string joinLines(const(string)[] lines) @safe pure nothrow
{
    size_t n = 0;
    foreach (l; lines)
        n += l.length + 1;
    auto buf = new char[n];
    size_t p = 0;
    foreach (l; lines)
    {
        buf[p .. p + l.length] = l[];
        p += l.length;
        buf[p++] = '\n';
    }
    return (() @trusted => cast(string) buf)();
}

/// Takes ownership of a freshly built char buffer as an immutable string.
string toImmutable(char[] buf) @trusted pure nothrow
{
    return cast(string) buf;
}
