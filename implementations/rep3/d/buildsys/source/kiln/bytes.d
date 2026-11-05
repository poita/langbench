/// Byte-string helpers. Kiln strings are byte strings, so nothing here
/// decodes UTF-8: every function works on `char` code units as raw bytes.
module kiln.bytes;

import core.stdc.string : memchr, memcmp;
import std.exception : assumeUnique;

/// Index of the first occurrence of `needle` in `hay` at or after `from`, or
/// `size_t.max` when there is none. An empty needle matches at `from`.
size_t findBytes(const(char)[] hay, const(char)[] needle, size_t from = 0) @trusted pure nothrow @nogc
{
    immutable n = needle.length;
    if (from > hay.length)
        return size_t.max;
    if (n == 0)
        return from;
    if (n > hay.length)
        return size_t.max;
    immutable last = hay.length - n;
    size_t i = from;
    immutable c0 = needle[0];
    while (i <= last)
    {
        auto p = cast(const(char)*) memchr(hay.ptr + i, c0, last - i + 1);
        if (p is null)
            return size_t.max;
        i = p - hay.ptr;
        if (n == 1 || memcmp(hay.ptr + i + 1, needle.ptr + 1, n - 1) == 0)
            return i;
        ++i;
    }
    return size_t.max;
}

/// True when `s` begins with `prefix`.
bool startsWithBytes(const(char)[] s, const(char)[] prefix) @trusted pure nothrow @nogc
{
    return s.length >= prefix.length && (prefix.length == 0 || memcmp(s.ptr, prefix.ptr, prefix.length) == 0);
}

/// True when `s` ends with `suffix`.
bool endsWithBytes(const(char)[] s, const(char)[] suffix) @trusted pure nothrow @nogc
{
    return s.length >= suffix.length
        && (suffix.length == 0 || memcmp(s.ptr + s.length - suffix.length, suffix.ptr, suffix.length) == 0);
}

/// Lines of a byte string: split at every `\n`; a trailing empty piece is
/// dropped and an empty string has no lines. The result slices `c`.
string[] splitLines(string c) pure nothrow
{
    string[] r;
    if (c.length == 0)
        return r;
    size_t start = 0;
    foreach (i; 0 .. c.length)
    {
        if (c[i] == '\n')
        {
            r ~= c[start .. i];
            start = i + 1;
        }
    }
    if (start < c.length)
        r ~= c[start .. $];
    return r;
}

/// Number of lines of `c` (see `splitLines`) without materialising them.
size_t countLines(const(char)[] c) pure nothrow @nogc
{
    if (c.length == 0)
        return 0;
    size_t n = 0;
    foreach (ch; c)
        if (ch == '\n')
            ++n;
    if (c[$ - 1] != '\n')
        ++n;
    return n;
}

/// A growable byte buffer producing an immutable string.
struct Buf
{
    private char[] data;
    private size_t len;

    /// Append bytes.
    void put(const(char)[] s) pure nothrow @safe
    {
        if (len + s.length > data.length)
            grow(s.length);
        data[len .. len + s.length] = s[];
        len += s.length;
    }

    /// Append one byte.
    void putc(char c) pure nothrow @safe
    {
        if (len + 1 > data.length)
            grow(1);
        data[len++] = c;
    }

    /// Append the decimal form of an integer.
    void putInt(long v) pure nothrow @safe
    {
        char[24] tmp;
        size_t i = tmp.length;
        bool neg = v < 0;
        ulong u = neg ? cast(ulong)(-(v + 1)) + 1 : cast(ulong) v;
        do
        {
            tmp[--i] = cast(char)('0' + u % 10);
            u /= 10;
        }
        while (u != 0);
        if (neg)
            tmp[--i] = '-';
        put(tmp[i .. $]);
    }

    /// Current length in bytes.
    @property size_t length() const pure nothrow @nogc
    {
        return len;
    }

    /// Reserve room for `n` more bytes.
    void reserve(size_t n) pure nothrow @safe
    {
        if (len + n > data.length)
            grow(n);
    }

    /// The accumulated string. The buffer must not be used afterwards.
    string take() pure nothrow @trusted
    {
        auto r = data[0 .. len];
        data = null;
        len = 0;
        return assumeUnique(r);
    }

    private void grow(size_t extra) pure nothrow @safe
    {
        size_t want = len + extra;
        size_t cap = data.length * 2;
        if (cap < want)
            cap = want;
        if (cap < 64)
            cap = 64;
        data.length = cap;
    }
}

/// Decimal text of an integer.
string intText(long v) pure nothrow
{
    Buf b;
    b.putInt(v);
    return b.take();
}

/// Replace every occurrence of `from` (non-empty) in `s` with `to`, scanning
/// left to right without overlaps.
string replaceAll(string s, const(char)[] from, const(char)[] to) pure nothrow
in (from.length > 0)
{
    size_t pos = 0;
    auto first = findBytes(s, from, 0);
    if (first == size_t.max)
        return s;
    Buf b;
    b.reserve(s.length);
    while (true)
    {
        auto idx = findBytes(s, from, pos);
        if (idx == size_t.max)
            break;
        b.put(s[pos .. idx]);
        b.put(to);
        pos = idx + from.length;
    }
    b.put(s[pos .. $]);
    return b.take();
}
