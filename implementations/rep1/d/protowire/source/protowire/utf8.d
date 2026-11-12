/// Strict UTF-8 validation (RFC 3629).
module protowire.utf8;

/// Returns true if `s` is well-formed UTF-8: no overlong forms, no surrogates
/// (U+D800..U+DFFF), nothing above U+10FFFF and no truncated sequences.
/// NUL bytes are allowed.
bool isValidUtf8(scope const(ubyte)[] s) @safe pure nothrow @nogc
{
    immutable n = s.length;
    size_t i = 0;
    while (i < n)
    {
        immutable b = s[i];
        if (b < 0x80)
        {
            ++i;
        }
        else if (b < 0xC2)
        {
            return false; // stray continuation byte or overlong 2-byte lead
        }
        else if (b < 0xE0)
        {
            if (i + 1 >= n || (s[i + 1] & 0xC0) != 0x80)
                return false;
            i += 2;
        }
        else if (b < 0xF0)
        {
            if (i + 2 >= n)
                return false;
            immutable b1 = s[i + 1];
            if ((b1 & 0xC0) != 0x80 || (s[i + 2] & 0xC0) != 0x80)
                return false;
            if (b == 0xE0 && b1 < 0xA0)
                return false; // overlong
            if (b == 0xED && b1 >= 0xA0)
                return false; // surrogate
            i += 3;
        }
        else if (b < 0xF5)
        {
            if (i + 3 >= n)
                return false;
            immutable b1 = s[i + 1];
            if ((b1 & 0xC0) != 0x80 || (s[i + 2] & 0xC0) != 0x80 || (s[i + 3] & 0xC0) != 0x80)
                return false;
            if (b == 0xF0 && b1 < 0x90)
                return false; // overlong
            if (b == 0xF4 && b1 >= 0x90)
                return false; // > U+10FFFF
            i += 4;
        }
        else
        {
            return false;
        }
    }
    return true;
}

@safe pure nothrow @nogc unittest
{
    assert(isValidUtf8([]));
    assert(isValidUtf8(cast(const(ubyte)[]) "héllo 日本語 😀\0"));
    assert(!isValidUtf8([0xff]));
    assert(!isValidUtf8([0xc0, 0xaf]));             // overlong
    assert(!isValidUtf8([0xe0, 0x80, 0x80]));       // overlong
    assert(!isValidUtf8([0xed, 0xa0, 0x80]));       // surrogate
    assert(isValidUtf8([0xed, 0x9f, 0xbf]));        // U+D7FF
    assert(!isValidUtf8([0xf4, 0x90, 0x80, 0x80])); // U+110000
    assert(isValidUtf8([0xf4, 0x8f, 0xbf, 0xbf]));  // U+10FFFF
    assert(!isValidUtf8([0xf0, 0x80, 0x80, 0x80])); // overlong
    assert(!isValidUtf8([0xc3]));                   // truncated
    assert(!isValidUtf8([0xe2, 0x82]));
    assert(!isValidUtf8([0x80, 0x80, 0x80, 0x80, 0x80]));
    assert(!isValidUtf8([0xf8, 0x88, 0x80, 0x80, 0x80]));
}
