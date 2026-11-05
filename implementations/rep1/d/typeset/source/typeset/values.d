/// Lexical helpers shared by the settings parser and the document parser:
/// length and integer literals, `key = value` lines and column arithmetic.
module typeset.values;

import typeset.arith : codepointCount, fdiv;

/// Millipoints per unit, or 0 when the text is not a unit.
private long unitMillipoints(const(char)[] u) pure nothrow @nogc @safe
{
    switch (u)
    {
    case "":
        return 1;
    case "pt":
        return 1000;
    case "mm":
        return 2835;
    case "cm":
        return 28350;
    case "in":
        return 72000;
    case "pc":
        return 12000;
    default:
        return 0;
    }
}

/// Parses a length literal (`[-]digits[.digits][unit]`) to millipoints.
/// Returns false on any lexical error or when the value does not fit.
bool parseLength(const(char)[] s, out long result) pure nothrow @nogc @safe
{
    size_t i;
    bool neg;
    if (i < s.length && s[i] == '-')
    {
        neg = true;
        ++i;
    }
    size_t ds = i;
    long whole;
    while (i < s.length && s[i] >= '0' && s[i] <= '9')
    {
        if (i - ds >= 15)
            return false;
        whole = whole * 10 + (s[i] - '0');
        ++i;
    }
    if (i == ds)
        return false;
    long frac;
    long pow = 1;
    if (i < s.length && s[i] == '.')
    {
        ++i;
        size_t fs = i;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
        {
            if (i - fs >= 3)
                return false;
            frac = frac * 10 + (s[i] - '0');
            pow *= 10;
            ++i;
        }
        if (i == fs)
            return false;
    }
    immutable long unit = unitMillipoints(s[i .. $]);
    if (unit == 0)
        return false;
    long v = fdiv((whole * pow + frac) * unit, pow);
    result = neg ? -v : v;
    return true;
}

/// Parses `[-]digits`.
bool parseInteger(const(char)[] s, out long result) pure nothrow @nogc @safe
{
    size_t i;
    bool neg;
    if (i < s.length && s[i] == '-')
    {
        neg = true;
        ++i;
    }
    if (i >= s.length || s.length - i > 15)
        return false;
    long v;
    foreach (c; s[i .. $])
    {
        if (c < '0' || c > '9')
            return false;
        v = v * 10 + (c - '0');
    }
    result = neg ? -v : v;
    return true;
}

/// True for the characters allowed in setting and metadata keys.
bool isKeyChar(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';
}

/// The shape `[ \t]* KEY [ \t]* "=" VALUE` of an assignment line.
struct Assignment
{
    bool ok; /// whether the line has the shape
    size_t keyStart; /// byte offset of the first non-blank character
    size_t keyEnd; ///
    size_t valueStart; /// byte offset of the first character of the trimmed value
    size_t valueEnd; ///
    /// The key text.
    const(char)[] key(const(char)[] line) const pure nothrow @nogc @safe
    {
        return line[keyStart .. keyEnd];
    }
    /// The trimmed value text.
    const(char)[] value(const(char)[] line) const pure nothrow @nogc @safe
    {
        return line[valueStart .. valueEnd];
    }
}

/// Splits an assignment line; `keyStart` is set even when the shape is wrong.
Assignment parseAssignment(const(char)[] line, bool allowTab) pure nothrow @nogc @safe
{
    Assignment a;
    size_t i;
    bool blank(char c) => c == ' ' || (allowTab && c == '\t');
    while (i < line.length && blank(line[i]))
        ++i;
    a.keyStart = i;
    while (i < line.length && isKeyChar(line[i]))
        ++i;
    a.keyEnd = i;
    if (a.keyEnd == a.keyStart)
        return a;
    while (i < line.length && blank(line[i]))
        ++i;
    if (i >= line.length || line[i] != '=')
        return a;
    ++i;
    while (i < line.length && blank(line[i]))
        ++i;
    size_t e = line.length;
    while (e > i && blank(line[e - 1]))
        --e;
    a.valueStart = i;
    a.valueEnd = e;
    a.ok = true;
    return a;
}

/// 1-based column, in Unicode scalar values, of byte offset `off` in `line`.
int columnAt(const(char)[] line, size_t off) pure nothrow @nogc @safe
{
    if (off > line.length)
        off = line.length;
    return cast(int)(codepointCount(line[0 .. off]) + 1);
}

/// Splits text into lines on `\n`; a final empty piece after a trailing
/// newline is not a line.
const(char)[][] splitLines(const(char)[] text) pure nothrow @safe
{
    const(char)[][] r;
    size_t start;
    foreach (i, c; text)
        if (c == '\n')
        {
            r ~= text[start .. i];
            start = i + 1;
        }
    if (start < text.length)
        r ~= text[start .. $];
    return r;
}

/// Encodes a code point as UTF-8, appending to `buf`.
void putUtf8(ref char[] buf, uint c) pure nothrow @safe
{
    if (c < 0x80)
        buf ~= cast(char) c;
    else if (c < 0x800)
    {
        buf ~= cast(char)(0xC0 | (c >> 6));
        buf ~= cast(char)(0x80 | (c & 0x3F));
    }
    else if (c < 0x10000)
    {
        buf ~= cast(char)(0xE0 | (c >> 12));
        buf ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf ~= cast(char)(0x80 | (c & 0x3F));
    }
    else
    {
        buf ~= cast(char)(0xF0 | (c >> 18));
        buf ~= cast(char)(0x80 | ((c >> 12) & 0x3F));
        buf ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf ~= cast(char)(0x80 | (c & 0x3F));
    }
}

/// Decodes the code point starting at `s[i]` and advances `i` past it.
/// Malformed bytes decode as U+FFFD (inputs are guaranteed valid UTF-8).
uint decodeAt(const(char)[] s, ref size_t i) pure nothrow @nogc @safe
{
    immutable ubyte c = s[i];
    if (c < 0x80)
    {
        ++i;
        return c;
    }
    int n = c >= 0xF0 ? 3 : (c >= 0xE0 ? 2 : 1);
    uint v = c & (0x3F >> n);
    ++i;
    foreach (_; 0 .. n)
    {
        if (i >= s.length)
            return 0xFFFD;
        v = (v << 6) | (s[i] & 0x3F);
        ++i;
    }
    return v;
}
