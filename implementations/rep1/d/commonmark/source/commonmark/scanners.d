/// Byte-level scanners for autolinks, link destinations and link titles.
/// All scanners work in place on the content and a position.
module commonmark.scanners;

import commonmark.chars;

/// Scan an autolink body. `pos` is the index just after `<`. On success
/// returns the index of the closing `>` and sets `isEmail`; otherwise -1.
ptrdiff_t scanAutolink(const(char)[] s, size_t pos, out bool isEmail) pure nothrow @nogc
{
    immutable n = s.length;
    size_t i = pos;

    // URI autolink: scheme (2-32 chars), ':', then no controls/space/</>.
    if (i < n && isAlpha(s[i]))
    {
        ++i;
        size_t k = 0;
        while (i < n && k < 31 && (isAlnum(s[i]) || s[i] == '.' || s[i] == '+' || s[i] == '-'))
        {
            ++i;
            ++k;
        }
        if (k >= 1 && i < n && s[i] == ':')
        {
            ++i;
            while (i < n && s[i] > ' ' && s[i] != '<' && s[i] != '>')
                ++i;
            if (i < n && s[i] == '>')
            {
                isEmail = false;
                return i;
            }
        }
    }

    // Email autolink.
    i = pos;
    while (i < n && isEmailLocal(s[i]))
        ++i;
    if (i == pos || i >= n || s[i] != '@')
        return -1;
    ++i;
    for (;;)
    {
        size_t st = i;
        while (i < n && (isAlnum(s[i]) || s[i] == '-'))
            ++i;
        immutable len = i - st;
        if (len == 0 || len > 63 || !isAlnum(s[st]) || !isAlnum(s[i - 1]))
            return -1;
        if (i < n && s[i] == '.')
        {
            ++i;
            continue;
        }
        break;
    }
    if (i < n && s[i] == '>')
    {
        isEmail = true;
        return i;
    }
    return -1;
}

private bool isEmailLocal(char c) pure nothrow @nogc
{
    if (isAlnum(c))
        return true;
    switch (c)
    {
    case '.': case '!': case '#': case '$': case '%': case '&': case '\'':
    case '*': case '+': case '/': case '=': case '?': case '^': case '_':
    case '`': case '{': case '|': case '}': case '~': case '-':
        return true;
    default:
        return false;
    }
}

/// Scan a link title starting at the opening delimiter `s[k]` (one of
/// `"`, `'`, `(`). Returns the index just after the closing delimiter, or -1.
/// The closing delimiter (and `(` in the parenthesised form) may appear
/// inside only when preceded by a backslash; the longest match wins.
ptrdiff_t scanTitle(const(char)[] s, size_t k) pure nothrow @nogc
{
    immutable open = s[k];
    immutable close = open == '(' ? ')' : open;
    ptrdiff_t cand = -1;
    for (size_t i = k + 1; i < s.length; ++i)
    {
        immutable c = s[i];
        if (c == close)
        {
            if (s[i - 1] == '\\')
                cand = i;
            else
                return i + 1;
        }
        else if (open == '(' && c == '(' && s[i - 1] != '\\')
            break;
    }
    return cand < 0 ? -1 : cand + 1;
}

/// The parts of an inline link following the `(`.
struct LinkTail
{
    /// Raw (undecoded) destination bounds.
    size_t destStart, destEnd;
    /// Raw title bounds (without delimiters), if `hasTitle`.
    size_t titleStart, titleEnd;
    bool hasTitle;
    /// Index just after the closing `)`.
    size_t end;
}

private size_t skipWs(const(char)[] s, size_t i) pure nothrow @nogc
{
    while (i < s.length && isWhitespace(s[i]))
        ++i;
    return i;
}

/// Parse `dest [title] )` starting just after the `(`. Returns false if the
/// text is not a valid inline link tail.
bool scanLinkTail(const(char)[] s, size_t p, out LinkTail r) pure nothrow @nogc
{
    immutable n = s.length;
    size_t i = skipWs(s, p);
    if (i >= n)
        return false;
    if (s[i] == '<')
    {
        size_t j = i + 1;
        while (j < n)
        {
            immutable c = s[j];
            if (c == '>')
                break;
            if (c == '\\')
                j += 2;
            else if (c == '\n' || c == '<')
                return false;
            else
                ++j;
        }
        if (j >= n)
            return false;
        r.destStart = i + 1;
        r.destEnd = j;
        i = j + 1;
    }
    else
    {
        size_t j = i;
        int nest = 0;
        while (j < n)
        {
            immutable c = s[j];
            if (c == '\\' && j + 1 < n && isAsciiPunct(s[j + 1]))
                j += 2;
            else if (c == '(')
            {
                ++nest;
                ++j;
                if (nest > 32)
                    return false;
            }
            else if (c == ')')
            {
                if (nest == 0)
                    break;
                --nest;
                ++j;
            }
            else if (isWhitespace(c))
                break;
            else
                ++j;
        }
        if (j >= n || nest != 0)
            return false;
        r.destStart = i;
        r.destEnd = j;
        i = j;
    }

    size_t k = skipWs(s, i);
    if (k > i && k < n && (s[k] == '"' || s[k] == '\'' || s[k] == '('))
    {
        immutable e = scanTitle(s, k);
        if (e >= 0)
        {
            r.hasTitle = true;
            r.titleStart = k + 1;
            r.titleEnd = e - 1;
            k = skipWs(s, e);
        }
    }
    if (k >= n || s[k] != ')')
        return false;
    r.end = k + 1;
    return true;
}
