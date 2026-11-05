/// ASCII character classification helpers (the `cmark_is*` family).
module commonmark.chars;

pure nothrow @nogc @safe:

/// Space or tab.
bool isSpaceOrTab(char c)
{
    return c == ' ' || c == '\t';
}

/// Space, tab, LF, VT, FF or CR.
bool isWhitespace(char c)
{
    return c == ' ' || (c >= '\t' && c <= '\r');
}

/// ASCII punctuation: ``!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~``.
bool isAsciiPunct(char c)
{
    return (c >= '!' && c <= '/') || (c >= ':' && c <= '@')
        || (c >= '[' && c <= '`') || (c >= '{' && c <= '~');
}

/// 0-9.
bool isDigit(char c)
{
    return c >= '0' && c <= '9';
}

/// 0-9, a-f, A-F.
bool isHexDigit(char c)
{
    return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/// Value of a hexadecimal digit.
uint hexValue(char c)
{
    return isDigit(c) ? c - '0' : (c | 0x20) - 'a' + 10;
}

/// a-z, A-Z.
bool isAlpha(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/// Letters and digits.
bool isAlnum(char c)
{
    return isAlpha(c) || isDigit(c);
}
