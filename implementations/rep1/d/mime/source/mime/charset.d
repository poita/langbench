/// Character-set decoding: ASCII, UTF-8 (maximal-subpart replacement),
/// Latin-1 and cp1252.
module mime.charset;

import std.array : Appender, appender;

@safe:

/// Normalises a charset name: strips SPACE/TAB and lower-cases ASCII letters.
string normalizeCharset(string name) pure nothrow
{
    import mime.text : stripBlanks, toLowerAscii;
    return toLowerAscii(stripBlanks(name));
}

/// The tables `decode` can use.
enum Charset { ascii, utf8, latin1, cp1252 }

/// Maps a (not necessarily normalised) charset name onto a table.
/// Unknown and empty names select cp1252.
Charset charsetFor(string name) pure nothrow
{
    switch (normalizeCharset(name))
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

private immutable wchar[32] cp1252High = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
];

/// Appends the UTF-8 encoding of a code point.
void putCodePoint(ref Appender!string app, uint cp) pure nothrow
{
    if (cp < 0x80)
        app.put(cast(char) cp);
    else if (cp < 0x800)
    {
        app.put(cast(char)(0xC0 | (cp >> 6)));
        app.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else if (cp < 0x10000)
    {
        app.put(cast(char)(0xE0 | (cp >> 12)));
        app.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        app.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else
    {
        app.put(cast(char)(0xF0 | (cp >> 18)));
        app.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
        app.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        app.put(cast(char)(0x80 | (cp & 0x3F)));
    }
}

/// Decodes `bytes` as UTF-8, replacing invalid input per the maximal-subpart
/// rule (each maximal prefix of a valid sequence becomes one U+FFFD).
string decodeUtf8(const(ubyte)[] bytes) pure nothrow
{
    auto app = appender!string();
    app.reserve(bytes.length);
    size_t i = 0;
    const n = bytes.length;
    while (i < n)
    {
        const b0 = bytes[i];
        if (b0 < 0x80)
        {
            app.put(cast(char) b0);
            ++i;
            continue;
        }
        uint need;       // total sequence length
        ubyte lo = 0x80, hi = 0xBF;
        uint cp;
        if (b0 >= 0xC2 && b0 <= 0xDF)
        {
            need = 2;
            cp = b0 & 0x1F;
        }
        else if (b0 >= 0xE0 && b0 <= 0xEF)
        {
            need = 3;
            cp = b0 & 0x0F;
            if (b0 == 0xE0) lo = 0xA0;
            else if (b0 == 0xED) hi = 0x9F;
        }
        else if (b0 >= 0xF0 && b0 <= 0xF4)
        {
            need = 4;
            cp = b0 & 0x07;
            if (b0 == 0xF0) lo = 0x90;
            else if (b0 == 0xF4) hi = 0x8F;
        }
        else
        {
            app.put("\uFFFD");
            ++i;
            continue;
        }
        size_t j = i + 1;
        bool ok = true;
        foreach (k; 1 .. need)
        {
            if (j >= n)
            {
                ok = false;
                break;
            }
            const b = bytes[j];
            const bool inRange = k == 1 ? (b >= lo && b <= hi) : (b >= 0x80 && b <= 0xBF);
            if (!inRange)
            {
                ok = false;
                break;
            }
            cp = (cp << 6) | (b & 0x3F);
            ++j;
        }
        if (ok)
            putCodePoint(app, cp);
        else
            app.put("\uFFFD");
        i = j;
    }
    return app.data;
}

/// Decodes `bytes` using the named charset (see `charsetFor`).
string decode(const(ubyte)[] bytes, string charset) pure nothrow
{
    final switch (charsetFor(charset))
    {
    case Charset.utf8:
        return decodeUtf8(bytes);
    case Charset.ascii:
    {
        auto app = appender!string();
        foreach (b; bytes)
            if (b < 0x80) app.put(cast(char) b);
            else app.put("\uFFFD");
        return app.data;
    }
    case Charset.latin1:
    {
        auto app = appender!string();
        foreach (b; bytes)
            putCodePoint(app, b);
        return app.data;
    }
    case Charset.cp1252:
    {
        auto app = appender!string();
        foreach (b; bytes)
            putCodePoint(app, (b >= 0x80 && b < 0xA0) ? cp1252High[b - 0x80] : b);
        return app.data;
    }
    }
}

pure nothrow unittest
{
    static const(ubyte)[] u(string s) @trusted { return cast(const(ubyte)[]) s; }
    assert(decode(u("caf\xe9"), "ISO-8859-1") == "café");
    assert(decode(u("smart\x92quote"), " windows-1252\t") == "smart’quote");
    assert(decode(u("\x81"), "") == "\u0081");
    assert(decode(u("a\xe9"), "us-ascii") == "a\uFFFD");
    assert(decode(u("\xc3\xa9"), "UTF8") == "é");
    assert(decode(u("x"), "klingon") == "x");
}

pure nothrow unittest
{
    static const(ubyte)[] u(string s) @trusted { return cast(const(ubyte)[]) s; }
    // Examples from the specification.
    assert(decodeUtf8(u("\xe2\x28\xa1")) == "\uFFFD(\uFFFD");
    assert(decodeUtf8(u("\xf0\x9f")) == "\uFFFD");
    assert(decodeUtf8(u("\xed\xa0\x80")) == "\uFFFD\uFFFD\uFFFD");
    assert(decodeUtf8(u("\xc0\x80")) == "\uFFFD\uFFFD");
    assert(decodeUtf8(u("\xe0\x80\x80")) == "\uFFFD\uFFFD\uFFFD");
    assert(decodeUtf8(u("\xf4\x90\x80\x80")) == "\uFFFD\uFFFD\uFFFD\uFFFD");
    assert(decodeUtf8(u("\xe1\x80")) == "\uFFFD");
    assert(decodeUtf8(u("\xe1\x80A")) == "\uFFFDA");
    assert(decodeUtf8(u("\xf0\x9f\x98\x80")) == "\U0001F600");
}
