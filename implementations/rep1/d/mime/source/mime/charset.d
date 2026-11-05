/// Character-set decoding to UTF-8 (`decode(bytes, charset)` in the spec).
///
/// Only four tables exist: ASCII, UTF-8 (with the maximal-subpart
/// replacement rule), Latin-1 and cp1252. Every unknown name means cp1252.
module mime.charset;

import mime.ascii;
import mime.buffer;

/// The tables a charset name can select.
enum Charset
{
    ascii,
    utf8,
    latin1,
    cp1252,
}

/// Normalises a charset name: strips SPACE/TAB and lower-cases ASCII letters.
string normalizeCharsetName(const(char)[] name) @safe pure nothrow
{
    return toLowerAscii(stripBlanks(name).idup);
}

/// Maps a charset name (normalised or not) to its table.
Charset charsetFor(const(char)[] name) @safe pure nothrow
{
    switch (normalizeCharsetName(name))
    {
    case "us-ascii", "ascii", "iso-ir-6", "ansi_x3.4-1968", "iso646-us":
        return Charset.ascii;
    case "utf-8", "utf8", "unicode-1-1-utf-8":
        return Charset.utf8;
    case "iso-8859-1", "iso8859-1", "latin-1", "latin1", "l1", "8859-1", "iso_8859-1":
        return Charset.latin1;
    default:
        return Charset.cp1252;
    }
}

private static immutable ushort[32] cp1252High = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
];

private void putCodePoint(ref ByteBuffer o, uint cp) @safe pure nothrow
{
    if (cp < 0x80)
        o.put(cast(ubyte) cp);
    else if (cp < 0x800)
    {
        o.put(cast(ubyte)(0xC0 | (cp >> 6)));
        o.put(cast(ubyte)(0x80 | (cp & 0x3F)));
    }
    else
    {
        o.put(cast(ubyte)(0xE0 | (cp >> 12)));
        o.put(cast(ubyte)(0x80 | ((cp >> 6) & 0x3F)));
        o.put(cast(ubyte)(0x80 | (cp & 0x3F)));
    }
}

private immutable ubyte[3] replacementChar = [0xEF, 0xBF, 0xBD];

/// Decodes `bytes` as UTF-8, replacing invalid input by U+FFFD with the
/// maximal-subpart rule. Appends the UTF-8 result to `o`.
void decodeUtf8Into(ref ByteBuffer o, scope const(ubyte)[] s) @safe pure nothrow
{
    o.reserve(s.length);
    size_t i = 0;
    size_t run = 0; // start of the pending run of valid bytes
    immutable n = s.length;
    while (i < n)
    {
        immutable b0 = s[i];
        if (b0 < 0x80)
        {
            i++;
            continue;
        }
        uint len = 0;
        ubyte lo = 0x80, hi = 0xBF;
        if (b0 >= 0xC2 && b0 <= 0xDF)
            len = 2;
        else if (b0 >= 0xE0 && b0 <= 0xEF)
        {
            len = 3;
            if (b0 == 0xE0)
                lo = 0xA0;
            else if (b0 == 0xED)
                hi = 0x9F;
        }
        else if (b0 >= 0xF0 && b0 <= 0xF4)
        {
            len = 4;
            if (b0 == 0xF0)
                lo = 0x90;
            else if (b0 == 0xF4)
                hi = 0x8F;
        }
        if (len == 0)
        {
            o.put(s[run .. i]);
            o.put(replacementChar[]);
            i++;
            run = i;
            continue;
        }
        size_t j = i + 1;
        bool ok = true;
        foreach (k; 1 .. len)
        {
            if (j >= n || s[j] < (k == 1 ? lo : 0x80) || s[j] > (k == 1 ? hi : 0xBF))
            {
                ok = false;
                break;
            }
            j++;
        }
        if (ok)
        {
            i = j;
            continue;
        }
        o.put(s[run .. i]);
        o.put(replacementChar[]);
        i = j;
        run = i;
    }
    o.put(s[run .. n]);
}

private void decodeSingleByteInto(ref ByteBuffer o, scope const(ubyte)[] s, bool cp1252) @safe pure nothrow
{
    o.reserve(s.length * 2);
    size_t run = 0;
    foreach (i, b; s)
    {
        if (b < 0x80)
            continue;
        o.put(s[run .. i]);
        run = i + 1;
        if (cp1252 && b < 0xA0)
            putCodePoint(o, cp1252High[b - 0x80]);
        else
            putCodePoint(o, b);
    }
    o.put(s[run .. $]);
}

private void decodeAsciiInto(ref ByteBuffer o, scope const(ubyte)[] s) @safe pure nothrow
{
    o.reserve(s.length);
    size_t run = 0;
    foreach (i, b; s)
    {
        if (b < 0x80)
            continue;
        o.put(s[run .. i]);
        o.put(replacementChar[]);
        run = i + 1;
    }
    o.put(s[run .. $]);
}

/// Decodes `bytes` with the table selected by `cs`, appending UTF-8 to `o`.
void decodeInto(ref ByteBuffer o, scope const(ubyte)[] bytes, Charset cs) @safe pure nothrow
{
    final switch (cs)
    {
    case Charset.ascii:
        decodeAsciiInto(o, bytes);
        break;
    case Charset.utf8:
        decodeUtf8Into(o, bytes);
        break;
    case Charset.latin1:
        decodeSingleByteInto(o, bytes, false);
        break;
    case Charset.cp1252:
        decodeSingleByteInto(o, bytes, true);
        break;
    }
}

/// `decode(bytes, charset)`: turns bytes into a (valid UTF-8) string using the
/// table the charset name selects.
string decode(scope const(ubyte)[] bytes, const(char)[] charset) @safe pure nothrow
{
    return decode(bytes, charsetFor(charset));
}

/// ditto
string decode(scope const(ubyte)[] bytes, Charset cs) @safe pure nothrow
{
    auto o = ByteBuffer(bytes.length + 16);
    decodeInto(o, bytes, cs);
    return o.toString();
}

/// Decodes header bytes as UTF-8.
string decodeUtf8(scope const(ubyte)[] bytes) @safe pure nothrow
{
    return decode(bytes, Charset.utf8);
}

/// Number of Unicode code points in a valid UTF-8 string.
size_t codePointCount(scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t n = 0;
    foreach (c; s)
        if ((c & 0xC0) != 0x80)
            n++;
    return n;
}
