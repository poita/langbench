/**
 * Object key ordering: UTF-16 code unit order, computed directly on UTF-8 bytes.
 */
module canonjson.keyorder;

import canonjson.scan : load64;

/**
 * Compares two valid UTF-8 keys in the order of their UTF-16 code unit
 * sequences (a proper prefix sorts first). Returns a negative number, zero or
 * a positive number.
 *
 * For code points in the Basic Multilingual Plane this equals code point
 * order; supplementary characters (surrogate pairs 0xD800..0xDFFF) sort before
 * U+E000..U+FFFF. Nothing is allocated and nothing is converted: the common
 * byte prefix is skipped, and only the two differing characters are decoded.
 */
int compareKeys(const(ubyte)[] a, const(ubyte)[] b) @safe pure nothrow @nogc
{
    immutable n = a.length < b.length ? a.length : b.length;
    size_t i = 0;
    while (i + 8 <= n && load64(a, i) == load64(b, i))
        i += 8;
    while (i < n && a[i] == b[i])
        ++i;
    if (i == n)
        return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);

    // Back up to the first byte of the character containing the difference.
    size_t j = i;
    while (j > 0 && (a[j] & 0xC0) == 0x80)
        --j;
    immutable ra = rank(decodeAt(a, j));
    immutable rb = rank(decodeAt(b, j));
    return ra < rb ? -1 : (ra > rb ? 1 : 0);
}

/// Sort rank of a code point: U+E000..U+FFFF ranks above all supplementary characters.
private uint rank(uint cp) @safe pure nothrow @nogc
{
    return (cp >= 0xE000 && cp <= 0xFFFF) ? cp + 0x110000 : cp;
}

/// Decodes the character starting at `s[i]` (valid UTF-8 assumed).
private uint decodeAt(const(ubyte)[] s, size_t i) @safe pure nothrow @nogc
{
    immutable b = s[i];
    if (b < 0x80)
        return b;
    if (b < 0xE0)
        return ((b & 0x1Fu) << 6) | (s[i + 1] & 0x3Fu);
    if (b < 0xF0)
        return ((b & 0x0Fu) << 12) | ((s[i + 1] & 0x3Fu) << 6) | (s[i + 2] & 0x3Fu);
    return ((b & 0x07u) << 18) | ((s[i + 1] & 0x3Fu) << 12)
        | ((s[i + 2] & 0x3Fu) << 6) | (s[i + 3] & 0x3Fu);
}
