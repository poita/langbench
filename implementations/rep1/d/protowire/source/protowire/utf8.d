/**
 * Strict UTF-8 validation (RFC 3629).
 */
module protowire.utf8;

/**
 * Whether `s` is well-formed UTF-8: no overlong forms, no surrogates
 * (U+D800..U+DFFF), nothing above U+10FFFF, no truncated sequences.
 * NUL bytes are allowed.
 */
bool isValidUtf8(const(ubyte)[] s) pure nothrow @nogc @trusted
{
    const(ubyte)* p = s.ptr;
    const n = s.length;
    size_t i = 0;
    while (i < n)
    {
        // Skip ASCII eight bytes at a time.
        while (i + 8 <= n && ((*cast(const(ulong)*)(p + i)) & 0x8080808080808080UL) == 0)
            i += 8;
        if (i >= n)
            break;
        const c = p[i];
        if (c < 0x80)
        {
            i++;
            continue;
        }
        if (c < 0xc2)
            return false;
        if (c < 0xe0)
        {
            if (i + 1 >= n || (p[i + 1] & 0xc0) != 0x80)
                return false;
            i += 2;
        }
        else if (c < 0xf0)
        {
            if (i + 2 >= n)
                return false;
            const c1 = p[i + 1];
            if ((c1 & 0xc0) != 0x80 || (p[i + 2] & 0xc0) != 0x80)
                return false;
            if (c == 0xe0 && c1 < 0xa0)
                return false;
            if (c == 0xed && c1 >= 0xa0)
                return false;
            i += 3;
        }
        else if (c < 0xf5)
        {
            if (i + 3 >= n)
                return false;
            const c1 = p[i + 1];
            if ((c1 & 0xc0) != 0x80 || (p[i + 2] & 0xc0) != 0x80 || (p[i + 3] & 0xc0) != 0x80)
                return false;
            if (c == 0xf0 && c1 < 0x90)
                return false;
            if (c == 0xf4 && c1 >= 0x90)
                return false;
            i += 4;
        }
        else
            return false;
    }
    return true;
}
