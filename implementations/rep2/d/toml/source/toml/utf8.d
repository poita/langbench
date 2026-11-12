/// Minimal UTF-8 helpers: strict validation and code point encoding.
module toml.utf8;

/**
 * Finds the first byte offset at which `data` is not well-formed UTF-8
 * (rejecting overlong forms, surrogates and values above U+10FFFF).
 * Returns `size_t.max` when the input is valid.
 */
size_t findInvalidUtf8(const(ubyte)[] data) @safe pure nothrow @nogc
{
    size_t i = 0;
    immutable n = data.length;
    while (i < n)
    {
        immutable ubyte c = data[i];
        if (c < 0x80)
        {
            i++;
            continue;
        }
        size_t len;
        uint lo = 0x80, hi = 0xBF; // allowed range of the second byte
        if (c >= 0xC2 && c <= 0xDF)
            len = 2;
        else if (c >= 0xE0 && c <= 0xEF)
        {
            len = 3;
            if (c == 0xE0) lo = 0xA0;       // no overlongs
            else if (c == 0xED) hi = 0x9F;  // no surrogates
        }
        else if (c >= 0xF0 && c <= 0xF4)
        {
            len = 4;
            if (c == 0xF0) lo = 0x90;       // no overlongs
            else if (c == 0xF4) hi = 0x8F;  // nothing above U+10FFFF
        }
        else
            return i;
        if (i + len > n)
            return i;
        if (data[i + 1] < lo || data[i + 1] > hi)
            return i;
        foreach (k; 2 .. len)
            if ((data[i + k] & 0xC0) != 0x80)
                return i;
        i += len;
    }
    return size_t.max;
}

/// True when `cp` is a Unicode scalar value (not a surrogate, <= U+10FFFF).
bool isScalarValue(uint cp) @safe pure nothrow @nogc
{
    return cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF);
}

/// Appends the UTF-8 encoding of the scalar value `cp` to `sink`.
void encodeUtf8(Sink)(ref Sink sink, uint cp)
{
    if (cp < 0x80)
        sink.put(cast(char) cp);
    else if (cp < 0x800)
    {
        sink.put(cast(char)(0xC0 | (cp >> 6)));
        sink.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else if (cp < 0x10000)
    {
        sink.put(cast(char)(0xE0 | (cp >> 12)));
        sink.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        sink.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else
    {
        sink.put(cast(char)(0xF0 | (cp >> 18)));
        sink.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
        sink.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        sink.put(cast(char)(0x80 | (cp & 0x3F)));
    }
}

unittest
{
    import std.array : appender;

    assert(findInvalidUtf8(cast(const(ubyte)[]) "héllo €𝄞") == size_t.max);
    assert(findInvalidUtf8([0xFF]) == 0);
    assert(findInvalidUtf8([0x61, 0xC0, 0x80]) == 1);        // overlong
    assert(findInvalidUtf8([0xED, 0xA0, 0x80]) == 0);        // surrogate
    assert(findInvalidUtf8([0xF4, 0x90, 0x80, 0x80]) == 0);  // > U+10FFFF
    assert(findInvalidUtf8([0xE2, 0x82]) == 0);              // truncated
    assert(findInvalidUtf8([0xE0, 0x80, 0x80]) == 0);        // overlong
    assert(findInvalidUtf8([0xFE, 0xFF]) == 0);              // UTF-16 BOM

    auto a = appender!string();
    encodeUtf8(a, 0x24);
    encodeUtf8(a, 0xE9);
    encodeUtf8(a, 0x20AC);
    encodeUtf8(a, 0x1D11E);
    assert(a.data == "$é€𝄞");
    assert(isScalarValue(0x10FFFF) && !isScalarValue(0xD800) && !isScalarValue(0x110000));
}
