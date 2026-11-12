/**
 * Strict UTF-8 (RFC 3629) validation and encoding.
 *
 * Rejects overlong forms, encoded surrogates, code points above U+10FFFF and
 * truncated sequences.
 */
module jsoncanon.utf8;

/**
 * Returns `true` if `data` is entirely well-formed UTF-8. Runs in a single
 * forward pass with an ASCII fast path.
 */
bool isValidUtf8(scope const(ubyte)[] data) @trusted pure nothrow @nogc
{
    const(ubyte)* p = data.ptr;
    const(ubyte)* end = p + data.length;
    while (p < end)
    {
        // ASCII fast path: eight bytes at a time.
        while (end - p >= 8)
        {
            ulong w = void;
            (cast(ubyte*) &w)[0 .. 8] = p[0 .. 8];
            if (w & 0x8080_8080_8080_8080UL)
                break;
            p += 8;
        }
        if (p >= end)
            break;
        immutable ubyte c = *p;
        if (c < 0x80)
        {
            ++p;
            continue;
        }
        immutable size_t left = end - p;
        if (c < 0xC2)
            return false; // continuation byte or overlong 2-byte lead
        if (c < 0xE0)
        {
            if (left < 2 || (p[1] & 0xC0) != 0x80)
                return false;
            p += 2;
        }
        else if (c < 0xF0)
        {
            if (left < 3)
                return false;
            immutable ubyte c1 = p[1];
            if ((c1 & 0xC0) != 0x80 || (p[2] & 0xC0) != 0x80)
                return false;
            if (c == 0xE0 && c1 < 0xA0) // overlong
                return false;
            if (c == 0xED && c1 >= 0xA0) // surrogates
                return false;
            p += 3;
        }
        else if (c < 0xF5)
        {
            if (left < 4)
                return false;
            immutable ubyte c1 = p[1];
            if ((c1 & 0xC0) != 0x80 || (p[2] & 0xC0) != 0x80 || (p[3] & 0xC0) != 0x80)
                return false;
            if (c == 0xF0 && c1 < 0x90) // overlong
                return false;
            if (c == 0xF4 && c1 >= 0x90) // > U+10FFFF
                return false;
            p += 4;
        }
        else
            return false;
    }
    return true;
}

/**
 * Appends the UTF-8 encoding of the Unicode scalar value `cp` to `sink`
 * (anything with `put(char)`-compatible `~=`, e.g. `char[]` or an
 * `Appender!(char[])`).
 *
 * `cp` must be a scalar value (not a surrogate, at most U+10FFFF).
 */
void encodeUtf8(Sink)(ref Sink sink, uint cp)
in (cp < 0xD800 || (cp > 0xDFFF && cp <= 0x10FFFF))
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

version (unittest)
{
    private bool valid(scope const(ubyte)[] b) @safe
    {
        return isValidUtf8(b);
    }
}

@safe unittest
{
    assert(valid([]));
    assert(valid(cast(const(ubyte)[]) "hello, world, this is longer than eight bytes"));
    assert(valid(cast(const(ubyte)[]) "héllo 😀  ￿"));
    assert(valid([0xF4, 0x8F, 0xBF, 0xBF])); // U+10FFFF
    assert(valid([0xED, 0x9F, 0xBF])); // U+D7FF
}

@safe unittest
{
    assert(!valid([0x80])); // stray continuation
    assert(!valid([0xC0, 0x80])); // overlong NUL
    assert(!valid([0xC1, 0xBF])); // overlong
    assert(!valid([0xE0, 0x80, 0x80])); // overlong
    assert(!valid([0xF0, 0x80, 0x80, 0x80])); // overlong
    assert(!valid([0xED, 0xA0, 0x80])); // U+D800
    assert(!valid([0xED, 0xBF, 0xBF])); // U+DFFF
    assert(!valid([0xF4, 0x90, 0x80, 0x80])); // U+110000
    assert(!valid([0xF5, 0x80, 0x80, 0x80]));
    assert(!valid([0xFF]));
    assert(!valid([0xC3])); // truncated
    assert(!valid([0xE2, 0x82])); // truncated
    assert(!valid([0xF0, 0x9F, 0x98])); // truncated
    assert(!valid([0xC3, 0x28])); // bad continuation
    // Invalid byte after a long ASCII run (exercises the fast path boundary).
    const(ubyte)[] ascii = cast(const(ubyte)[]) "abcdefghijklmnop";
    assert(!valid(ascii ~ cast(ubyte) 0xFF));
}

@safe unittest
{
    import std.array : appender;

    auto a = appender!(char[]);
    foreach (cp; [0x41u, 0xE9, 0x20AC, 0x1F600, 0x10FFFF])
        encodeUtf8(a, cp);
    assert(a.data == "Aé€\U0001F600\U0010FFFF");
    assert(isValidUtf8(cast(const(ubyte)[]) a.data));
}
