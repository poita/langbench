/// Strict UTF-8 helpers.
module toml.utf8;

/// Returns the index of the first byte that is not part of well-formed UTF-8
/// (overlong forms, surrogates and values above U+10FFFF are malformed), or
/// `s.length` when the whole input is valid.
size_t firstInvalidUtf8(scope const(char)[] s) pure nothrow @nogc @trusted
{
    size_t i = 0;
    immutable n = s.length;
    const(ubyte)* p = cast(const(ubyte)*) s.ptr;
    while (i < n)
    {
        immutable c = p[i];
        if (c < 0x80)
        {
            i++;
            continue;
        }
        size_t need;
        uint lo = 0x80, hi = 0xBF; // allowed range of the second byte
        if (c >= 0xC2 && c <= 0xDF)
            need = 1;
        else if (c >= 0xE0 && c <= 0xEF)
        {
            need = 2;
            if (c == 0xE0)
                lo = 0xA0; // no overlongs
            else if (c == 0xED)
                hi = 0x9F; // no surrogates
        }
        else if (c >= 0xF0 && c <= 0xF4)
        {
            need = 3;
            if (c == 0xF0)
                lo = 0x90;
            else if (c == 0xF4)
                hi = 0x8F;
        }
        else
            return i;
        if (i + need >= n)
            return i;
        immutable c1 = p[i + 1];
        if (c1 < lo || c1 > hi)
            return i;
        foreach (k; 2 .. need + 1)
            if ((p[i + k] & 0xC0) != 0x80)
                return i;
        i += need + 1;
    }
    return n;
}

/// Appends the UTF-8 encoding of scalar value `cp` to `buf`.
void appendUtf8(ref char[] buf, uint cp) pure nothrow
{
    if (cp < 0x80)
        buf ~= cast(char) cp;
    else if (cp < 0x800)
    {
        buf ~= cast(char)(0xC0 | (cp >> 6));
        buf ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else if (cp < 0x10000)
    {
        buf ~= cast(char)(0xE0 | (cp >> 12));
        buf ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else
    {
        buf ~= cast(char)(0xF0 | (cp >> 18));
        buf ~= cast(char)(0x80 | ((cp >> 12) & 0x3F));
        buf ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf ~= cast(char)(0x80 | (cp & 0x3F));
    }
}

/// True if `cp` is a Unicode scalar value.
bool isScalarValue(uint cp) pure nothrow @nogc @safe
{
    return cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF);
}
