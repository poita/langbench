/**
 * Strict UTF-8 validation and encoding helpers.
 */
module toml.utf8;

/**
 * Finds the first invalid UTF-8 sequence in `s`.
 *
 * Rejects truncated sequences, overlong forms, encoded surrogates and code
 * points above U+10FFFF. Returns the byte index of the problem, or `size_t.max`
 * when `s` is well formed.
 */
size_t firstInvalidUtf8(const(char)[] s) @trusted pure nothrow @nogc
{
    immutable n = s.length;
    size_t i = 0;
    while (i < n)
    {
        immutable ubyte b = s[i];
        if (b < 0x80)
        {
            ++i;
            continue;
        }
        size_t need;
        ubyte lo = 0x80, hi = 0xBF;
        if (b >= 0xC2 && b <= 0xDF)
            need = 1;
        else if (b == 0xE0) { need = 2; lo = 0xA0; }
        else if (b == 0xED) { need = 2; hi = 0x9F; }
        else if (b >= 0xE1 && b <= 0xEF)
            need = 2;
        else if (b == 0xF0) { need = 3; lo = 0x90; }
        else if (b == 0xF4) { need = 3; hi = 0x8F; }
        else if (b >= 0xF1 && b <= 0xF3)
            need = 3;
        else
            return i;
        if (i + need >= n)
            return i;
        immutable ubyte b1 = s[i + 1];
        if (b1 < lo || b1 > hi)
            return i;
        foreach (k; 2 .. need + 1)
        {
            immutable ubyte bk = s[i + k];
            if (bk < 0x80 || bk > 0xBF)
                return i;
        }
        i += need + 1;
    }
    return size_t.max;
}

/// Appends the UTF-8 encoding of the Unicode scalar value `c` to `buf`.
void appendUtf8(ref char[] buf, uint c) @safe pure nothrow
in (c <= 0x10FFFF && (c < 0xD800 || c > 0xDFFF))
{
    if (c < 0x80)
        buf ~= cast(char) c;
    else if (c < 0x800)
    {
        buf ~= cast(char)(0xC0 | (c >> 6));
        buf ~= cast(char)(0x80 | (c & 0x3F));
    }
    else if (c < 0x10000)
    {
        buf ~= cast(char)(0xE0 | (c >> 12));
        buf ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf ~= cast(char)(0x80 | (c & 0x3F));
    }
    else
    {
        buf ~= cast(char)(0xF0 | (c >> 18));
        buf ~= cast(char)(0x80 | ((c >> 12) & 0x3F));
        buf ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf ~= cast(char)(0x80 | (c & 0x3F));
    }
}

unittest
{
    assert(firstInvalidUtf8("hello é € 😀") == size_t.max);
    assert(firstInvalidUtf8("") == size_t.max);
    assert(firstInvalidUtf8("ab\xFFcd") == 2);
    assert(firstInvalidUtf8("\xC0\x80") == 0);        // overlong
    assert(firstInvalidUtf8("\xED\xA0\x80") == 0);    // surrogate
    assert(firstInvalidUtf8("\xF4\x90\x80\x80") == 0); // > U+10FFFF
    assert(firstInvalidUtf8("a\xE2\x82") == 1);       // truncated at end
    assert(firstInvalidUtf8("a\xF0\x9F\x98") == 1);
    assert(firstInvalidUtf8("a\xC3") == 1);
    assert(firstInvalidUtf8("\x80") == 0);
    char[] b;
    appendUtf8(b, 0x1F600);
    appendUtf8(b, 'a');
    appendUtf8(b, 0xE9);
    assert(b == "😀aé");
}
