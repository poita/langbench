/**
 * Low-level text helpers shared by the block parser, the inline parser and the
 * HTML renderer: ASCII character classes, HTML escaping, entity and backslash
 * decoding, and URL encoding.
 *
 * All functions here are byte oriented; the input is assumed to be UTF-8 and
 * multi-byte sequences are simply passed through.
 */
module commonmark.text;

import std.array : Appender;

/// The output buffer type used throughout the library.
alias Sink = Appender!(char[]);

@safe pure nothrow:

/// Encodes the code point `cp` (which must be valid) as UTF-8 into `buf`;
/// returns the number of bytes written.
size_t encodeUtf8(ref char[4] buf, dchar cp)
{
    if (cp < 0x80)
    {
        buf[0] = cast(char) cp;
        return 1;
    }
    if (cp < 0x800)
    {
        buf[0] = cast(char)(0xC0 | (cp >> 6));
        buf[1] = cast(char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000)
    {
        buf[0] = cast(char)(0xE0 | (cp >> 12));
        buf[1] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = cast(char)(0x80 | (cp & 0x3F));
        return 3;
    }
    buf[0] = cast(char)(0xF0 | (cp >> 18));
    buf[1] = cast(char)(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = cast(char)(0x80 | (cp & 0x3F));
    return 4;
}

/// Whitespace in the sense of cmark's `cmark_isspace`: space, TAB, LF, VT, FF, CR.
bool isSpace(char c)
{
    return c == ' ' || (c >= '\t' && c <= '\r');
}

/// A space or a tab.
bool isSpaceOrTab(char c)
{
    return c == ' ' || c == '\t';
}

/// ASCII punctuation: ``!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~``.
bool isPunct(char c)
{
    return (c >= '!' && c <= '/') || (c >= ':' && c <= '@')
        || (c >= '[' && c <= '`') || (c >= '{' && c <= '~');
}

/// ASCII decimal digit.
bool isDigit(char c)
{
    return c >= '0' && c <= '9';
}

/// ASCII letter.
bool isAlpha(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/// ASCII letter or digit.
bool isAlnum(char c)
{
    return isAlpha(c) || isDigit(c);
}

/// ASCII hexadecimal digit.
bool isHexDigit(char c)
{
    return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private int hexValue(char c)
{
    if (c <= '9')
        return c - '0';
    return (c | 0x20) - 'a' + 10;
}

/// Returns `s` without trailing whitespace (the `isSpace` set).
inout(char)[] trimRight(inout(char)[] s)
{
    size_t n = s.length;
    while (n > 0 && isSpace(s[n - 1]))
        --n;
    return s[0 .. n];
}

/// Returns `s` without leading whitespace (the `isSpace` set).
inout(char)[] trimLeft(inout(char)[] s)
{
    size_t i = 0;
    while (i < s.length && isSpace(s[i]))
        ++i;
    return s[i .. $];
}

/// Returns `s` without leading and trailing whitespace.
inout(char)[] trim(inout(char)[] s)
{
    return trimLeft(trimRight(s));
}

/// Appends `s` to `o`, replacing `&`, `<`, `>` and `"` with entities.
void escapeHtml(ref Sink o, const(char)[] s) @safe
{
    size_t start = 0;
    foreach (i, c; s)
    {
        string rep;
        switch (c)
        {
        case '&':
            rep = "&amp;";
            break;
        case '<':
            rep = "&lt;";
            break;
        case '>':
            rep = "&gt;";
            break;
        case '"':
            rep = "&quot;";
            break;
        default:
            continue;
        }
        o.put(s[start .. i]);
        o.put(rep);
        start = i + 1;
    }
    o.put(s[start .. $]);
}

/**
 * Tries to match an entity reference at `s[i]`, which must be `&`.
 *
 * Recognised: decimal references with 1 to 7 digits, hexadecimal references
 * with 1 to 6 digits, and the four named references `&amp;` `&lt;` `&gt;`
 * `&quot;`. Invalid code points (0, surrogates, above U+10FFFF) decode to
 * U+FFFD.
 *
 * Returns: the number of bytes matched (including `&` and `;`), or 0.
 */
size_t matchEntity(const(char)[] s, size_t i, out dchar cp)
{
    immutable n = s.length;
    size_t j = i + 1;
    if (j >= n)
        return 0;
    if (s[j] == '#')
    {
        ++j;
        uint v = 0;
        size_t digits = 0;
        if (j < n && (s[j] == 'x' || s[j] == 'X'))
        {
            ++j;
            while (j < n && isHexDigit(s[j]) && digits < 6)
            {
                v = v * 16 + hexValue(s[j]);
                ++j;
                ++digits;
            }
        }
        else
        {
            while (j < n && isDigit(s[j]) && digits < 7)
            {
                v = v * 10 + (s[j] - '0');
                ++j;
                ++digits;
            }
        }
        if (digits == 0 || j >= n || s[j] != ';')
            return 0;
        if (v == 0 || (v >= 0xD800 && v <= 0xDFFF) || v > 0x10FFFF)
            v = 0xFFFD;
        cp = cast(dchar) v;
        return j + 1 - i;
    }
    static immutable string[4] names = ["amp;", "lt;", "gt;", "quot;"];
    static immutable dchar[4] values = ['&', '<', '>', '"'];
    foreach (k, name; names)
    {
        if (n - j >= name.length && s[j .. j + name.length] == name)
        {
            cp = values[k];
            return 1 + name.length;
        }
    }
    return 0;
}

/// Decodes all entity references in `s` (see `matchEntity`).
string decodeEntities(string s) @safe pure nothrow
{
    size_t first = size_t.max;
    foreach (i, c; s)
        if (c == '&')
        {
            first = i;
            break;
        }
    if (first == size_t.max)
        return s;
    char[] o;
    o.reserve(s.length);
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '&')
        {
            dchar cp;
            immutable m = matchEntity(s, i, cp);
            if (m)
            {
                char[4] buf;
                immutable len = encodeUtf8(buf, cp);
                o ~= buf[0 .. len];
                i += m;
                continue;
            }
        }
        o ~= s[i++];
    }
    return (() @trusted => cast(string) o)();
}

/// Removes backslash escapes: a backslash before ASCII punctuation is deleted.
string unescapeBackslashes(string s) @safe pure nothrow
{
    size_t first = size_t.max;
    foreach (i, c; s)
        if (c == '\\')
        {
            first = i;
            break;
        }
    if (first == size_t.max)
        return s;
    char[] o;
    o.reserve(s.length);
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '\\' && i + 1 < s.length && isPunct(s[i + 1]))
            ++i;
        o ~= s[i++];
    }
    return (() @trusted => cast(string) o)();
}

/// Entity decoding followed by backslash unescaping, as used for link
/// destinations, titles and info strings.
string cleanString(string s) @safe pure nothrow
{
    return unescapeBackslashes(decodeEntities(s));
}

private bool startsWithNoCase(const(char)[] s, string prefix)
{
    if (s.length < prefix.length)
        return false;
    foreach (i, c; prefix)
    {
        char d = s[i];
        if (d >= 'A' && d <= 'Z')
            d += 32;
        if (d != c)
            return false;
    }
    return true;
}

/// True if a destination is dropped by the renderer for safety
/// (`javascript:`, `vbscript:`, `file:`, `data:` except a few image types).
bool isUnsafeUrl(const(char)[] url)
{
    if (startsWithNoCase(url, "javascript:") || startsWithNoCase(url, "vbscript:")
        || startsWithNoCase(url, "file:"))
        return true;
    if (startsWithNoCase(url, "data:"))
    {
        return !(startsWithNoCase(url, "data:image/png")
                || startsWithNoCase(url, "data:image/gif")
                || startsWithNoCase(url, "data:image/jpeg")
                || startsWithNoCase(url, "data:image/webp"));
    }
    return false;
}

private bool isHrefSafe(char c)
{
    if (isAlnum(c))
        return true;
    switch (c)
    {
    case '-': case '_': case '.': case '~': case '!': case '#': case '$':
    case '%': case '(': case ')': case '*': case '+': case ',': case '/':
    case ':': case ';': case '=': case '?': case '@':
        return true;
    default:
        return false;
    }
}

/// Appends the percent-encoded form of the URL `url` (for use in an `href`
/// or `src` attribute) to `o`. Unsafe URL schemes produce nothing.
void escapeHref(ref Sink o, const(char)[] url) @safe
{
    if (isUnsafeUrl(url))
        return;
    static immutable hex = "0123456789ABCDEF";
    size_t start = 0;
    foreach (i, c; url)
    {
        if (isHrefSafe(c))
            continue;
        o.put(url[start .. i]);
        start = i + 1;
        if (c == '&')
            o.put("&amp;");
        else if (c == '\'')
            o.put("&#x27;");
        else
        {
            o.put('%');
            o.put(hex[(cast(ubyte) c) >> 4]);
            o.put(hex[c & 15]);
        }
    }
    o.put(url[start .. $]);
}

unittest
{
    Sink o;
    escapeHtml(o, `a<b>&"c"`);
    assert(o.data == "a&lt;b&gt;&amp;&quot;c&quot;");
}

unittest
{
    dchar cp;
    assert(matchEntity("&amp;x", 0, cp) == 5 && cp == '&');
    assert(matchEntity("&#65;", 0, cp) == 5 && cp == 'A');
    assert(matchEntity("&#x42;", 0, cp) == 6 && cp == 'B');
    assert(matchEntity("&#0;", 0, cp) == 4 && cp == '�');
    assert(matchEntity("&#12345678;", 0, cp) == 0);
    assert(matchEntity("&#;", 0, cp) == 0);
    assert(matchEntity("&amp", 0, cp) == 0);
    assert(matchEntity("&copy;", 0, cp) == 0);
    assert(decodeEntities("a &lt; b &#92;*") == "a < b \\*");
}

unittest
{
    assert(unescapeBackslashes(`\*a\b\\`) == `*a\b\`);
    assert(cleanString(`&#92;*`) == "*");
    assert(cleanString(`\&amp;`) == "&");
}

unittest
{
    Sink o;
    escapeHref(o, "/my uri?a=1&b='x'%20é");
    assert(o.data == "/my%20uri?a=1&amp;b=&#x27;x&#x27;%20%C3%A9");
    Sink p;
    escapeHref(p, "JavaScript:alert(1)");
    assert(p.data == "");
    Sink q;
    escapeHref(q, "data:image/png;base64,AAA");
    assert(q.data == "data:image/png;base64,AAA");
}
