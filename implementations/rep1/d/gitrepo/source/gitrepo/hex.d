/// Hexadecimal helpers.
module gitrepo.hex;

/// Lowercase hexadecimal rendering of `bytes`.
string toHex(scope const(ubyte)[] bytes) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    auto r = new char[](bytes.length * 2);
    foreach (i, b; bytes)
    {
        r[2 * i] = digits[b >> 4];
        r[2 * i + 1] = digits[b & 15];
    }
    return (() @trusted => cast(string) r)();
}

/// Value of one hexadecimal digit (either case), or -1.
int hexValue(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// True when `s` is non-empty and made only of hexadecimal digits.
bool isHex(scope const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0)
        return false;
    foreach (c; s)
        if (hexValue(c) < 0)
            return false;
    return true;
}

/// True when `s` is non-empty and made only of lowercase hexadecimal digits.
bool isLowerHex(scope const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length == 0)
        return false;
    foreach (c; s)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            return false;
    return true;
}

unittest
{
    assert(toHex([0x00, 0xff, 0x1a]) == "00ff1a");
    assert(hexValue('F') == 15 && hexValue('g') == -1);
    assert(isHex("DeadBeef") && !isHex("") && !isHex("xyz"));
    assert(isLowerHex("abc123") && !isLowerHex("ABC"));
}
