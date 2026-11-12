/**
 * Byte-string helpers.
 *
 * Kiln strings are byte strings: D's `string` is used purely as an immutable
 * byte array, and none of the helpers here ever decode UTF-8, so arbitrary
 * binary content is safe.
 */
module kiln.bytes;

/// Index of the first occurrence of `needle` in `hay` at or after `from`, or -1.
ptrdiff_t indexOf(const(char)[] hay, const(char)[] needle, size_t from = 0) @safe pure nothrow @nogc
{
    immutable n = needle.length;
    if (from > hay.length)
        return -1;
    if (n == 0)
        return cast(ptrdiff_t) from;
    if (n > hay.length)
        return -1;
    immutable last = hay.length - n;
    immutable first = needle[0];
    for (size_t i = from; i <= last; i++)
    {
        if (hay[i] != first)
            continue;
        if (hay[i .. i + n] == needle)
            return cast(ptrdiff_t) i;
    }
    return -1;
}

/// True if `s` contains `needle` as a byte substring.
bool contains(const(char)[] s, const(char)[] needle) @safe pure nothrow @nogc
{
    return indexOf(s, needle) >= 0;
}

/// True if `s` begins with `p`.
bool startsWith(const(char)[] s, const(char)[] p) @safe pure nothrow @nogc
{
    return s.length >= p.length && s[0 .. p.length] == p;
}

/// True if `s` ends with `p`.
bool endsWith(const(char)[] s, const(char)[] p) @safe pure nothrow @nogc
{
    return s.length >= p.length && s[$ - p.length .. $] == p;
}

/// Unsigned byte-wise comparison; a proper prefix is smaller.
int cmpBytes(const(char)[] a, const(char)[] b) @trusted pure nothrow @nogc
{
    import core.stdc.string : memcmp;

    immutable n = a.length < b.length ? a.length : b.length;
    if (n)
    {
        immutable r = memcmp(a.ptr, b.ptr, n);
        if (r != 0)
            return r < 0 ? -1 : 1;
    }
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}

/**
 * The lines of a byte string: split at every LF, and a final empty piece
 * (content ending in LF) is discarded. Empty content has no lines. CR is
 * ordinary content.
 */
string[] splitLines(string c) @safe pure nothrow
{
    string[] lines;
    if (c.length == 0)
        return lines;
    size_t start = 0;
    foreach (i; 0 .. c.length)
    {
        if (c[i] == '\n')
        {
            lines ~= c[start .. i];
            start = i + 1;
        }
    }
    if (start < c.length)
        lines ~= c[start .. $];
    return lines;
}

/// Number of lines of `c` (see $(LREF splitLines)) without allocating them.
size_t countLines(const(char)[] c) @safe pure nothrow @nogc
{
    if (c.length == 0)
        return 0;
    size_t n = 0;
    foreach (ch; c)
        if (ch == '\n')
            n++;
    return c[$ - 1] == '\n' ? n : n + 1;
}

/// Concatenates `lines`, each followed by one LF.
string joinLines(const(string)[] lines) @safe pure nothrow
{
    size_t total = 0;
    foreach (l; lines)
        total += l.length + 1;
    auto buf = new char[total];
    size_t p = 0;
    foreach (l; lines)
    {
        buf[p .. p + l.length] = l[];
        p += l.length;
        buf[p++] = '\n';
    }
    return (() @trusted => cast(string) buf)();
}

/// Replaces every non-overlapping occurrence of `from` (left to right) with `to`.
string replaceAll(string s, const(char)[] from, const(char)[] to) @safe pure nothrow
in (from.length > 0)
{
    auto pos = indexOf(s, from);
    if (pos < 0)
        return s;
    char[] buf;
    buf.reserve(s.length);
    size_t cur = 0;
    while (pos >= 0)
    {
        buf ~= s[cur .. pos];
        buf ~= to;
        cur = pos + from.length;
        pos = indexOf(s, from, cur);
    }
    buf ~= s[cur .. $];
    return (() @trusted => cast(string) buf)();
}

/// ASCII-only upper-casing.
string toUpperAscii(string s) @safe pure nothrow
{
    char[] r = s.dup;
    foreach (ref c; r)
        if (c >= 'a' && c <= 'z')
            c -= 32;
    return (() @trusted => cast(string) r)();
}

/// ASCII-only lower-casing.
string toLowerAscii(string s) @safe pure nothrow
{
    char[] r = s.dup;
    foreach (ref c; r)
        if (c >= 'A' && c <= 'Z')
            c += 32;
    return (() @trusted => cast(string) r)();
}

/// The decimal representation of `v`.
string decimal(long v) @safe pure nothrow
{
    if (v == 0)
        return "0";
    char[24] tmp;
    size_t p = tmp.length;
    // Work in unsigned space so long.min is handled.
    ulong u = v < 0 ? cast(ulong)(-(v + 1)) + 1 : cast(ulong) v;
    while (u)
    {
        tmp[--p] = cast(char)('0' + u % 10);
        u /= 10;
    }
    if (v < 0)
        tmp[--p] = '-';
    return tmp[p .. $].idup;
}

@safe pure unittest
{
    assert(indexOf("abcabc", "ca") == 2);
    assert(indexOf("abc", "") == 0);
    assert(indexOf("abc", "d") == -1);
    assert(splitLines("a\nb\n") == ["a", "b"]);
    assert(splitLines("a\nb") == ["a", "b"]);
    assert(splitLines("a\n\nb\n") == ["a", "", "b"]);
    assert(splitLines("\n") == [""]);
    assert(splitLines("").length == 0);
    assert(countLines("a\nb") == 2 && countLines("a\n") == 1 && countLines("") == 0);
    assert(joinLines(["a", "b"]) == "a\nb\n");
    assert(replaceAll("aaa", "aa", "b") == "ba");
    assert(replaceAll("abc", "x", "y") == "abc");
    assert(cmpBytes("a", "ab") < 0 && cmpBytes("\xff", "a") > 0 && cmpBytes("x", "x") == 0);
    assert(decimal(0) == "0" && decimal(-12) == "-12" && decimal(long.min) == "-9223372036854775808");
    assert(toUpperAscii("aZ\xc3\xbc") == "AZ\xc3\xbc");
}
