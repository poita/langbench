/// Entity references, backslash escapes and UTF-8 encoding helpers.
module commonmark.entities;

import commonmark.buffer;
import commonmark.chars;

/// Append the UTF-8 encoding of `cp` to `b`.
void putUtf8(ref Buffer b, dchar cp) pure nothrow
{
    if (cp < 0x80)
        b.put(cast(char) cp);
    else if (cp < 0x800)
    {
        b.put(cast(char)(0xC0 | (cp >> 6)));
        b.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else if (cp < 0x10000)
    {
        b.put(cast(char)(0xE0 | (cp >> 12)));
        b.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        b.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else
    {
        b.put(cast(char)(0xF0 | (cp >> 18)));
        b.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
        b.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        b.put(cast(char)(0x80 | (cp & 0x3F)));
    }
}

private bool hasPrefix(const(char)[] s, size_t i, string prefix) pure nothrow @nogc
{
    return s.length - i >= prefix.length && s[i .. i + prefix.length] == prefix;
}

/// Try to match an entity reference at `s[i]` (which must be `&`).
/// Recognised: decimal (1-7 digits) and hexadecimal (1-6 digits) numeric
/// references and the named references `amp`, `lt`, `gt`, `quot`.
/// Returns the number of bytes matched (including `&` and `;`), or 0.
size_t matchEntity(const(char)[] s, size_t i, out dchar cp) pure nothrow @nogc
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
            while (j < n && isHexDigit(s[j]))
            {
                if (digits < 8)
                    v = v * 16 + hexValue(s[j]);
                ++digits;
                ++j;
            }
            if (digits < 1 || digits > 6)
                return 0;
        }
        else
        {
            while (j < n && isDigit(s[j]))
            {
                if (digits < 8)
                    v = v * 10 + (s[j] - '0');
                ++digits;
                ++j;
            }
            if (digits < 1 || digits > 7)
                return 0;
        }
        if (j >= n || s[j] != ';')
            return 0;
        cp = (v == 0 || (v >= 0xD800 && v <= 0xDFFF) || v > 0x10FFFF) ? 0xFFFD : cast(dchar) v;
        return j + 1 - i;
    }
    if (hasPrefix(s, j, "amp;"))
    {
        cp = '&';
        return 5;
    }
    if (hasPrefix(s, j, "lt;"))
    {
        cp = '<';
        return 4;
    }
    if (hasPrefix(s, j, "gt;"))
    {
        cp = '>';
        return 4;
    }
    if (hasPrefix(s, j, "quot;"))
    {
        cp = '"';
        return 6;
    }
    return 0;
}

/// Append `s` to `dst` with entity references decoded.
void decodeEntities(const(char)[] s, ref Buffer dst) pure nothrow
{
    size_t i = 0;
    immutable n = s.length;
    while (i < n)
    {
        size_t start = i;
        while (i < n && s[i] != '&')
            ++i;
        dst.put(s[start .. i]);
        if (i >= n)
            break;
        dchar cp;
        immutable m = matchEntity(s, i, cp);
        if (m)
        {
            putUtf8(dst, cp);
            i += m;
        }
        else
        {
            dst.put('&');
            ++i;
        }
    }
}

/// Append `s` to `dst` with backslashes before ASCII punctuation removed.
void unescapeBackslashes(const(char)[] s, ref Buffer dst) pure nothrow
{
    size_t i = 0;
    immutable n = s.length;
    while (i < n)
    {
        size_t start = i;
        while (i < n && s[i] != '\\')
            ++i;
        dst.put(s[start .. i]);
        if (i >= n)
            break;
        if (i + 1 < n && isAsciiPunct(s[i + 1]))
            ++i; // drop the backslash, keep the punctuation
        dst.put(s[i]);
        ++i;
    }
}

/// Entities decoded, then backslash escapes removed; appended to `dst`.
/// `scratch` is temporary storage.
void cleanText(const(char)[] s, ref Buffer dst, ref Buffer scratch) pure nothrow
{
    bool amp, bs;
    foreach (c; s)
    {
        amp |= c == '&';
        bs |= c == '\\';
    }
    if (!amp && !bs)
    {
        dst.put(s);
        return;
    }
    if (!amp)
    {
        unescapeBackslashes(s, dst);
        return;
    }
    scratch.clear();
    decodeEntities(s, scratch);
    unescapeBackslashes(scratch.data, dst);
}
