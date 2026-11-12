/// A single mutable document line with amortised in-place editing.
module textbuffer.line;

import core.stdc.string : memcpy, memmove;
import std.algorithm.comparison : max;
import std.array : uninitializedArray;

/// A growable text line.
///
/// Editing a line costs O(ℓ + m) where ℓ is the line length and m the length
/// of the inserted text; the backing buffer grows geometrically so repeated
/// edits of a long line do not reallocate each time.
struct Line
{
    private char[] buf;
    private uint len;

    /// Creates a line holding `a ~ b`.
    this(const(char)[] a, const(char)[] b = null) @trusted pure nothrow
    {
        immutable n = a.length + b.length;
        buf = uninitializedArray!(char[])(n);
        if (a.length)
            memcpy(buf.ptr, a.ptr, a.length);
        if (b.length)
            memcpy(buf.ptr + a.length, b.ptr, b.length);
        len = cast(uint) n;
    }

    /// The line's text (valid until the next mutation).
    const(char)[] text() const @safe pure nothrow @nogc
    {
        return buf[0 .. len];
    }

    /// Number of characters.
    size_t length() const @safe pure nothrow @nogc
    {
        return len;
    }

    /// Replaces the characters `[from, to)` by `ins`. `ins` must not alias the line.
    void replace(size_t from, size_t to, const(char)[] ins) @trusted pure nothrow
    in (from <= to && to <= len)
    {
        immutable newLen = len - (to - from) + ins.length;
        if (newLen > buf.length)
        {
            auto nb = uninitializedArray!(char[])(max(newLen, buf.length * 2));
            if (from)
                memcpy(nb.ptr, buf.ptr, from);
            if (ins.length)
                memcpy(nb.ptr + from, ins.ptr, ins.length);
            if (len > to)
                memcpy(nb.ptr + from + ins.length, buf.ptr + to, len - to);
            buf = nb;
        }
        else
        {
            if (len > to && from + ins.length != to)
                memmove(buf.ptr + from + ins.length, buf.ptr + to, len - to);
            if (ins.length)
                memcpy(buf.ptr + from, ins.ptr, ins.length);
        }
        len = cast(uint) newLen;
    }

    /// Cuts the line down to its first `n` characters.
    void truncate(size_t n) @safe pure nothrow @nogc
    in (n <= len)
    {
        len = cast(uint) n;
    }

    /// Appends `s` (which must not alias the line).
    void append(const(char)[] s) @safe pure nothrow
    {
        replace(len, len, s);
    }
}

@safe pure nothrow unittest
{
    auto l = Line("hello world");
    l.replace(5, 6, ", big ");
    assert(l.text == "hello, big world");
    l.replace(0, 5, "");
    assert(l.text == ", big world");
    l.truncate(5);
    l.append("!!!");
    assert(l.text == ", big!!!");
    assert(l.length == 8);
}

@safe pure nothrow unittest
{
    // Growth and shrinkage over many edits.
    auto l = Line("");
    foreach (i; 0 .. 1000)
        l.replace(l.length, l.length, "ab");
    assert(l.length == 2000);
    l.replace(0, 1990, "");
    assert(l.text == "ababababab");
    auto j = Line("ab", "cd");
    assert(j.text == "abcd");
}
