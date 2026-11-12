/**
 * Character-level helpers for the Markdown converter: ASCII classes, entity
 * references, backslash escapes and HTML escaping.
 */
module sitegen.markdown.entities;

import std.array : Appender;
import std.utf : encode;

/// Whether `c` is an ASCII punctuation character.
bool isAsciiPunct(char c) pure nothrow @nogc @safe
{
    return (c >= '!' && c <= '/') || (c >= ':' && c <= '@')
        || (c >= '[' && c <= '`') || (c >= '{' && c <= '~');
}

/// Whether `c` is in the `cmark_isspace` set: space, TAB, LF, VT, FF, CR.
bool isSpace(char c) pure nothrow @nogc @safe
{
    return c == ' ' || (c >= '\t' && c <= '\r');
}

/// Whether `c` is a space or a tab.
bool isSpaceOrTab(char c) pure nothrow @nogc @safe
{
    return c == ' ' || c == '\t';
}

/// Whether `c` is an ASCII letter.
bool isAlpha(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/// Whether `c` is an ASCII digit.
bool isDigit(char c) pure nothrow @nogc @safe
{
    return c >= '0' && c <= '9';
}

/// Whether `c` is an ASCII letter or digit.
bool isAlnum(char c) pure nothrow @nogc @safe
{
    return isAlpha(c) || isDigit(c);
}

/// Removes leading and trailing ASCII whitespace.
string trimAscii(string s) pure nothrow @nogc @safe
{
    size_t a = 0, b = s.length;
    while (a < b && isSpace(s[a])) a++;
    while (b > a && isSpace(s[b - 1])) b--;
    return s[a .. b];
}

private int hexValue(char c) pure nothrow @nogc @safe
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/**
 * Tries to match an entity reference whose `&` is at `s[pos - 1]`.
 *
 * Recognised are decimal references (1-7 digits), hexadecimal references
 * (1-6 digits) and the four named references `amp`, `lt`, `gt` and `quot`.
 *
 * Params:
 *   s = the text
 *   pos = index of the first character after the `&`
 *   decoded = receives the decoded text on success
 *   end = receives the index just after the `;` on success
 * Returns: whether a reference was matched.
 */
bool matchEntity(string s, size_t pos, out string decoded, out size_t end) pure @safe
{
    const n = s.length;
    if (pos >= n) return false;
    if (s[pos] == '#')
    {
        size_t i = pos + 1;
        uint cp = 0;
        size_t digits = 0;
        if (i < n && (s[i] == 'x' || s[i] == 'X'))
        {
            i++;
            while (i < n && hexValue(s[i]) >= 0 && digits < 7)
            {
                cp = cp * 16 + cast(uint) hexValue(s[i]);
                i++;
                digits++;
            }
            if (digits < 1 || digits > 6) return false;
        }
        else
        {
            while (i < n && isDigit(s[i]) && digits < 8)
            {
                cp = cp * 10 + (s[i] - '0');
                i++;
                digits++;
            }
            if (digits < 1 || digits > 7) return false;
        }
        if (i >= n || s[i] != ';') return false;
        if (cp == 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) cp = 0xFFFD;
        char[4] buf;
        const len = encode(buf, cast(dchar) cp);
        decoded = buf[0 .. len].idup;
        end = i + 1;
        return true;
    }
    static immutable string[2][4] names = [["amp;", "&"], ["lt;", "<"], ["gt;", ">"], ["quot;", "\""]];
    foreach (ref e; names)
    {
        if (s.length - pos >= e[0].length && s[pos .. pos + e[0].length] == e[0])
        {
            decoded = e[1];
            end = pos + e[0].length;
            return true;
        }
    }
    return false;
}

/// Replaces entity references in `s` by the characters they denote.
string decodeEntities(string s) pure @safe
{
    import std.string : indexOf;

    if (s.indexOf('&') < 0) return s;
    Appender!string o;
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '&')
        {
            string d;
            size_t e;
            if (matchEntity(s, i + 1, d, e))
            {
                o.put(d);
                i = e;
                continue;
            }
        }
        o.put(s[i]);
        i++;
    }
    return o.data;
}

/// Removes the backslash of every backslash escape (`\` + ASCII punctuation).
string unescapeBackslashes(string s) pure @safe
{
    import std.string : indexOf;

    if (s.indexOf('\\') < 0) return s;
    Appender!string o;
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '\\' && i + 1 < s.length && isAsciiPunct(s[i + 1]))
            i++;
        o.put(s[i]);
        i++;
    }
    return o.data;
}

/// Appends `s` to `o`, escaping `&`, `<`, `>` and `"`.
void escapeHtml(ref Appender!string o, string s) pure @safe
{
    size_t start = 0;
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
        o.put(s[start .. i]);
        o.put(rep);
        start = i + 1;
    }
    o.put(s[start .. $]);
}

private bool startsWithIgnoreCase(string s, string prefix) pure nothrow @nogc @safe
{
    if (s.length < prefix.length) return false;
    foreach (i, c; prefix)
    {
        char d = s[i];
        if (d >= 'A' && d <= 'Z') d += 32;
        if (d != c) return false;
    }
    return true;
}

private bool isDangerousUrl(string url) pure nothrow @nogc @safe
{
    if (startsWithIgnoreCase(url, "javascript:") || startsWithIgnoreCase(url, "vbscript:")
        || startsWithIgnoreCase(url, "file:"))
        return true;
    if (startsWithIgnoreCase(url, "data:"))
    {
        foreach (ok; ["data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp"])
            if (startsWithIgnoreCase(url, ok)) return false;
        return true;
    }
    return false;
}

/// Appends the `href`/`src` attribute value for the destination `url`.
void encodeHref(ref Appender!string o, string url) pure @safe
{
    static immutable string hex = "0123456789ABCDEF";
    if (isDangerousUrl(url)) return;
    foreach (char c; url)
    {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
        {
            o.put(c);
            continue;
        }
        switch (c)
        {
            case '-': case '_': case '.': case '~': case '!': case '#': case '$': case '%':
            case '(': case ')': case '*': case '+': case ',': case '/': case ':': case ';':
            case '=': case '?': case '@':
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
                o.put(hex[(cast(ubyte) c) >> 4]);
                o.put(hex[(cast(ubyte) c) & 15]);
        }
    }
}

unittest
{
    assert(decodeEntities("a &amp; b &#65;&#x42; &foo; &amp") == "a & b AB &foo; &amp");
    assert(decodeEntities("&#0;") == "�");
    assert(decodeEntities("&#12345678;") == "&#12345678;");
    assert(unescapeBackslashes(`\*a\b\\`) == `*a\b\`);
}

unittest
{
    Appender!string o;
    escapeHtml(o, `<a href="x">&</a>`);
    assert(o.data == "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;");
}

unittest
{
    Appender!string o;
    encodeHref(o, "/my uri?a=1&b='é'");
    assert(o.data == "/my%20uri?a=1&amp;b=&#x27;%C3%A9&#x27;");
    Appender!string p;
    encodeHref(p, "JavaScript:alert(1)");
    assert(p.data == "");
    Appender!string q;
    encodeHref(q, "data:image/png;base64,AA");
    assert(q.data == "data:image/png;base64,AA");
}
