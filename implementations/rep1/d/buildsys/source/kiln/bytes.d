/// Byte-string helpers. All functions work on bytes, never on code points.
module kiln.bytes;

/// Index of the first occurrence of `needle` in `hay` at or after `from`, or
/// `size_t.max` if there is none. An empty needle is found at `from`.
size_t findBytes(const(char)[] hay, const(char)[] needle, size_t from = 0) pure nothrow @nogc @safe
{
    if (needle.length == 0)
        return from <= hay.length ? from : size_t.max;
    if (needle.length > hay.length)
        return size_t.max;
    const last = hay.length - needle.length;
    const first = needle[0];
    for (size_t i = from; i <= last; ++i)
    {
        if (hay[i] != first)
            continue;
        if (hay[i .. i + needle.length] == needle)
            return i;
    }
    return size_t.max;
}

/// True if `hay` contains `needle` as a byte substring.
bool containsBytes(const(char)[] hay, const(char)[] needle) pure nothrow @nogc @safe
{
    return findBytes(hay, needle) != size_t.max;
}

/// Replaces every non-overlapping occurrence of the non-empty `from` by `to`,
/// scanning left to right.
string replaceAll(string s, const(char)[] from, const(char)[] to) pure @safe
{
    assert(from.length > 0);
    char[] result;
    size_t i = 0;
    while (true)
    {
        const j = findBytes(s, from, i);
        if (j == size_t.max)
            break;
        result ~= s[i .. j];
        result ~= to;
        i = j + from.length;
    }
    if (i == 0)
        return s;
    result ~= s[i .. $];
    return (() @trusted => cast(string) result)();
}

/// The lines of a file: split at every `\n`, dropping a final empty piece.
/// The returned slices are views into `c`.
string[] splitLines(string c) pure @safe
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

/// Renders a `long` in decimal.
string decimal(long v) pure nothrow @safe
{
    if (v == 0)
        return "0";
    char[24] buf;
    size_t i = buf.length;
    const neg = v < 0;
    ulong u = neg ? -cast(ulong) v : cast(ulong) v;
    while (u)
    {
        buf[--i] = cast(char)('0' + u % 10);
        u /= 10;
    }
    if (neg)
        buf[--i] = '-';
    return buf[i .. $].idup;
}
