/// Character classes, entity decoding, escaping and URL encoding helpers for
/// the Markdown converter.
module sitegen.markdown.text;

import std.array : Appender, appender;

/// ASCII punctuation character (CommonMark's definition).
bool isAsciiPunct(char c) pure nothrow @safe @nogc
{
    return (c >= '!' && c <= '/') || (c >= ':' && c <= '@')
        || (c >= '[' && c <= '`') || (c >= '{' && c <= '~');
}

/// The `cmark_isspace` set: space, TAB, LF, VT, FF, CR.
bool isAsciiWs(char c) pure nothrow @safe @nogc
{
    return c == ' ' || (c >= '\t' && c <= '\r');
}

/// Space or TAB.
bool isSpaceOrTab(char c) pure nothrow @safe @nogc
{
    return c == ' ' || c == '\t';
}

bool isAsciiAlpha(char c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

bool isAsciiDigit(char c) pure nothrow @safe @nogc
{
    return c >= '0' && c <= '9';
}

bool isAsciiAlnum(char c) pure nothrow @safe @nogc
{
    return isAsciiAlpha(c) || isAsciiDigit(c);
}

private int hexValue(char c) pure nothrow @safe @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// Remove leading and trailing whitespace (the `cmark_isspace` set).
inout(char)[] trimWs(inout(char)[] s) pure nothrow @safe @nogc
{
    size_t a = 0, b = s.length;
    while (a < b && isAsciiWs(s[a]))
        ++a;
    while (b > a && isAsciiWs(s[b - 1]))
        --b;
    return s[a .. b];
}

/// Try to match an entity reference starting at `s[pos] == '&'`.
///
/// Recognises `&amp;` `&lt;` `&gt;` `&quot;` and decimal / hexadecimal
/// numeric references. On success returns true, sets `length` to the number
/// of characters consumed (including `&` and `;`) and `cp` to the code point.
bool matchEntity(const(char)[] s, size_t pos, out size_t length, out dchar cp) pure nothrow @safe
{
    size_t i = pos + 1;
    if (i >= s.length)
        return false;
    if (s[i] == '#')
    {
        ++i;
        bool hex = i < s.length && (s[i] == 'x' || s[i] == 'X');
        if (hex)
            ++i;
        immutable maxDigits = hex ? 6 : 7;
        immutable base = hex ? 16 : 10;
        size_t digits = 0;
        uint value = 0;
        while (i < s.length)
        {
            int d = hexValue(s[i]);
            if (d < 0 || d >= base)
                break;
            if (++digits > maxDigits)
                return false;
            value = value * base + d;
            ++i;
        }
        if (digits == 0 || i >= s.length || s[i] != ';')
            return false;
        length = i + 1 - pos;
        cp = (value == 0 || (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF)
            ? cast(dchar) 0xFFFD : cast(dchar) value;
        return true;
    }
    static immutable string[4] names = ["amp;", "lt;", "gt;", "quot;"];
    static immutable dchar[4] values = ['&', '<', '>', '"'];
    foreach (k, name; names)
    {
        if (s.length - i >= name.length && s[i .. i + name.length] == name)
        {
            length = 1 + name.length;
            cp = values[k];
            return true;
        }
    }
    return false;
}

/// Append the UTF-8 encoding of `cp` (a valid Unicode scalar value).
void putCodePoint(ref Appender!(char[]) o, dchar cp) pure nothrow @safe
{
    if (cp < 0x80)
        o.put(cast(char) cp);
    else if (cp < 0x800)
    {
        o.put(cast(char)(0xC0 | (cp >> 6)));
        o.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else if (cp < 0x10000)
    {
        o.put(cast(char)(0xE0 | (cp >> 12)));
        o.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        o.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else
    {
        o.put(cast(char)(0xF0 | (cp >> 18)));
        o.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
        o.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        o.put(cast(char)(0x80 | (cp & 0x3F)));
    }
}

/// Replace every recognised entity reference in `s` by its character.
string decodeEntities(string s) pure nothrow @safe
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
    auto o = appender!(char[])();
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '&')
        {
            size_t len;
            dchar cp;
            if (matchEntity(s, i, len, cp))
            {
                putCodePoint(o, cp);
                i += len;
                continue;
            }
        }
        o.put(s[i]);
        ++i;
    }
    return o.data.idup;
}

/// Remove the backslash of every backslash escape (a `\` before ASCII punctuation).
string unescapeBackslashes(string s) pure nothrow @safe
{
    bool any;
    foreach (i, c; s)
        if (c == '\\' && i + 1 < s.length && isAsciiPunct(s[i + 1]))
        {
            any = true;
            break;
        }
    if (!any)
        return s;
    auto o = appender!(char[])();
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '\\' && i + 1 < s.length && isAsciiPunct(s[i + 1]))
            ++i;
        o.put(s[i]);
        ++i;
    }
    return o.data.idup;
}

/// Entities first, then backslash escapes: the treatment of destinations,
/// titles and info strings.
string cleanString(string s) pure nothrow @safe
{
    return unescapeBackslashes(decodeEntities(s));
}

/// Append `s` with `&`, `<`, `>` and `"` escaped.
void escapeHtml(ref Appender!(char[]) o, const(char)[] s) pure nothrow @safe
{
    size_t runStart = 0;
    foreach (i, c; s)
    {
        string rep;
        switch (c)
        {
        case '&': rep = "&amp;"; break;
        case '<': rep = "&lt;"; break;
        case '>': rep = "&gt;"; break;
        case '"': rep = "&quot;"; break;
        default: continue;
        }
        o.put(s[runStart .. i]);
        o.put(rep);
        runStart = i + 1;
    }
    o.put(s[runStart .. $]);
}

private bool startsWithCI(const(char)[] s, string prefix) pure nothrow @safe @nogc
{
    if (s.length < prefix.length)
        return false;
    foreach (i, p; prefix)
    {
        char c = s[i];
        if (c >= 'A' && c <= 'Z')
            c += 32;
        if (c != p)
            return false;
    }
    return true;
}

/// Append the attribute value for a link destination: unsafe schemes give an
/// empty value, everything else is percent-encoded as cmark does.
void putHref(ref Appender!(char[]) o, const(char)[] url) pure nothrow @safe
{
    static immutable string[4] bad = ["javascript:", "vbscript:", "file:", "data:"];
    static immutable string[4] okData = ["data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp"];
    foreach (b; bad)
    {
        if (startsWithCI(url, b))
        {
            bool allowed = false;
            if (b == "data:")
                foreach (ok; okData)
                    if (startsWithCI(url, ok))
                        allowed = true;
            if (!allowed)
                return;
        }
    }
    static immutable hexDigits = "0123456789ABCDEF";
    foreach (char c; url)
    {
        if (isAsciiAlnum(c))
        {
            o.put(c);
            continue;
        }
        switch (c)
        {
        case '-': case '_': case '.': case '~': case '!': case '#': case '$':
        case '%': case '(': case ')': case '*': case '+': case ',': case '/':
        case ':': case ';': case '=': case '?': case '@':
            o.put(c);
            break;
        case '&':
            o.put("&amp;");
            break;
        case '\'':
            o.put("&#x27;");
            break;
        default:
            o.put('%');
            o.put(hexDigits[(cast(ubyte) c) >> 4]);
            o.put(hexDigits[(cast(ubyte) c) & 15]);
            break;
        }
    }
}
