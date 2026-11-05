/**
 * Byte-level validation of a TOML document: strict UTF-8, no byte-order mark
 * and no CR that is not part of a CRLF pair. Everything else is checked by the
 * parser.
 */
module toml.validate;

import toml.node : TomlException;

/// Throws $(REF TomlException, toml,node) when `s` is not acceptable TOML text.
void validateDocument(const(char)[] s) pure @trusted
{
    immutable n = s.length;
    if (n >= 3 && s[0] == '\xEF' && s[1] == '\xBB' && s[2] == '\xBF')
        throw new TomlException("byte-order mark");
    size_t i = 0;
    while (i < n)
    {
        immutable ubyte c = s[i];
        if (c < 0x80)
        {
            if (c == '\r' && (i + 1 >= n || s[i + 1] != '\n'))
                throw new TomlException("bare carriage return", lineOf(s, i));
            ++i;
            continue;
        }
        size_t len;
        ubyte lo = 0x80, hi = 0xBF;
        if (c >= 0xC2 && c <= 0xDF)
            len = 2;
        else if (c >= 0xE0 && c <= 0xEF)
        {
            len = 3;
            if (c == 0xE0) lo = 0xA0;
            else if (c == 0xED) hi = 0x9F;
        }
        else if (c >= 0xF0 && c <= 0xF4)
        {
            len = 4;
            if (c == 0xF0) lo = 0x90;
            else if (c == 0xF4) hi = 0x8F;
        }
        else
            throw new TomlException("invalid UTF-8", lineOf(s, i));
        if (i + len > n)
            throw new TomlException("truncated UTF-8", lineOf(s, i));
        immutable ubyte c1 = s[i + 1];
        if (c1 < lo || c1 > hi)
            throw new TomlException("invalid UTF-8", lineOf(s, i));
        foreach (k; 2 .. len)
        {
            immutable ubyte ck = s[i + k];
            if (ck < 0x80 || ck > 0xBF)
                throw new TomlException("invalid UTF-8", lineOf(s, i));
        }
        i += len;
    }
}

/// 1-based line number of byte offset `pos`.
size_t lineOf(const(char)[] s, size_t pos) pure nothrow @safe @nogc
{
    size_t line = 1;
    foreach (c; s[0 .. pos < s.length ? pos : s.length])
        if (c == '\n')
            ++line;
    return line;
}
