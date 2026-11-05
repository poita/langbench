/// Whole-document byte validation performed before parsing.
module toml.utf8;

import toml.exception;

/**
 * Checks that `s` is strict UTF-8 (no overlongs, surrogates or values above
 * U+10FFFF), does not start with a byte-order mark, and contains no CR that
 * is not immediately followed by LF.
 *
 * Throws: `TomlException` describing the first problem found.
 */
void validateDocument(const(char)[] s) pure @safe
{
    immutable n = s.length;
    if (n >= 3 && s[0] == '\xEF' && s[1] == '\xBB' && s[2] == '\xBF')
        throw new TomlException("byte-order mark", 0);
    size_t i = 0;
    while (i < n)
    {
        immutable c = cast(ubyte) s[i];
        if (c < 0x80)
        {
            if (c == '\r' && (i + 1 >= n || s[i + 1] != '\n'))
                throw new TomlException("bare carriage return", i);
            i++;
            continue;
        }
        size_t need;
        ubyte lo = 0x80, hi = 0xBF;
        if (c >= 0xC2 && c <= 0xDF) need = 1;
        else if (c >= 0xE0 && c <= 0xEF)
        {
            need = 2;
            if (c == 0xE0) lo = 0xA0;
            else if (c == 0xED) hi = 0x9F;
        }
        else if (c >= 0xF0 && c <= 0xF4)
        {
            need = 3;
            if (c == 0xF0) lo = 0x90;
            else if (c == 0xF4) hi = 0x8F;
        }
        else throw new TomlException("invalid UTF-8", i);
        if (i + need >= n)
            throw new TomlException("truncated UTF-8", i);
        immutable b1 = cast(ubyte) s[i + 1];
        if (b1 < lo || b1 > hi) throw new TomlException("invalid UTF-8", i);
        foreach (k; 2 .. need + 1)
        {
            immutable b = cast(ubyte) s[i + k];
            if (b < 0x80 || b > 0xBF) throw new TomlException("invalid UTF-8", i);
        }
        i += need + 1;
    }
}
