/**
 * Strict UTF-8 (RFC 3629) validation.
 */
module canonjson.utf8;

import canonjson.scan : load64;

private enum ulong highs = 0x8080808080808080UL;

/**
 * Returns true if `s` is well-formed UTF-8: no overlong encodings, no encoded
 * surrogates (U+D800..U+DFFF), no code points above U+10FFFF and no truncated
 * sequences. The check is a single linear pass over the input.
 *
 * Note that a byte-order mark (EF BB BF) is valid UTF-8; rejecting it is the
 * caller's business (see `hasByteOrderMark`).
 */
bool validateUtf8(const(ubyte)[] s) @safe pure nothrow @nogc
{
    immutable n = s.length;
    size_t i = 0;
    while (i < n)
    {
        // Fast path: skip runs of ASCII eight bytes at a time.
        while (i + 8 <= n && (load64(s, i) & highs) == 0)
            i += 8;
        if (i >= n)
            break;
        immutable b = s[i];
        if (b < 0x80)
        {
            ++i;
            continue;
        }
        if (b < 0xC2)
            return false; // continuation byte or overlong 2-byte lead
        if (b < 0xE0)
        {
            if (i + 1 >= n || !isCont(s[i + 1]))
                return false;
            i += 2;
        }
        else if (b < 0xF0)
        {
            if (i + 2 >= n)
                return false;
            immutable b1 = s[i + 1];
            if (b == 0xE0 ? (b1 < 0xA0 || b1 > 0xBF) // overlong
                : b == 0xED ? (b1 < 0x80 || b1 > 0x9F) // surrogates
                : !isCont(b1))
                return false;
            if (!isCont(s[i + 2]))
                return false;
            i += 3;
        }
        else if (b < 0xF5)
        {
            if (i + 3 >= n)
                return false;
            immutable b1 = s[i + 1];
            if (b == 0xF0 ? (b1 < 0x90 || b1 > 0xBF) // overlong
                : b == 0xF4 ? (b1 < 0x80 || b1 > 0x8F) // above U+10FFFF
                : !isCont(b1))
                return false;
            if (!isCont(s[i + 2]) || !isCont(s[i + 3]))
                return false;
            i += 4;
        }
        else
            return false;
    }
    return true;
}

/// True if `s` starts with the UTF-8 byte-order mark EF BB BF.
bool hasByteOrderMark(const(ubyte)[] s) @safe pure nothrow @nogc
{
    return s.length >= 3 && s[0] == 0xEF && s[1] == 0xBB && s[2] == 0xBF;
}

private bool isCont(ubyte b) @safe pure nothrow @nogc
{
    return (b & 0xC0) == 0x80;
}

/// Appends the UTF-8 encoding of the scalar value `cp` to `sink` (any type with `put(ubyte)`).
void encodeUtf8(Sink)(ref Sink sink, uint cp)
{
    if (cp < 0x80)
        sink.put(cast(ubyte) cp);
    else if (cp < 0x800)
    {
        sink.put(cast(ubyte)(0xC0 | (cp >> 6)));
        sink.put(cast(ubyte)(0x80 | (cp & 0x3F)));
    }
    else if (cp < 0x10000)
    {
        sink.put(cast(ubyte)(0xE0 | (cp >> 12)));
        sink.put(cast(ubyte)(0x80 | ((cp >> 6) & 0x3F)));
        sink.put(cast(ubyte)(0x80 | (cp & 0x3F)));
    }
    else
    {
        sink.put(cast(ubyte)(0xF0 | (cp >> 18)));
        sink.put(cast(ubyte)(0x80 | ((cp >> 12) & 0x3F)));
        sink.put(cast(ubyte)(0x80 | ((cp >> 6) & 0x3F)));
        sink.put(cast(ubyte)(0x80 | (cp & 0x3F)));
    }
}
