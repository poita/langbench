/// Lowercase hexadecimal encoding and decoding.
module inflate.hex;

import inflate.error;

private static immutable char[16] digits = "0123456789abcdef";

/// Encode `data` as lowercase hex, two digits per byte.
string toHex(scope const(ubyte)[] data) @trusted pure nothrow
{
    auto r = new char[data.length * 2];
    foreach (i, b; data)
    {
        r[2 * i] = digits[b >> 4];
        r[2 * i + 1] = digits[b & 15];
    }
    return cast(string) r;
}

/**
 * Decode a hex string (either case) to bytes. Throws `InflateException`
 * (`InflateError.invalidHex`) on an odd length or a non-hex character.
 */
ubyte[] fromHex(scope const(char)[] text) @safe pure
{
    if (text.length & 1)
        fail(InflateError.invalidHex, "hex string has odd length");
    auto r = new ubyte[text.length / 2];
    foreach (i; 0 .. r.length)
        r[i] = cast(ubyte)((nibble(text[2 * i]) << 4) | nibble(text[2 * i + 1]));
    return r;
}

private uint nibble(char c) @safe pure
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    fail(InflateError.invalidHex, "invalid hex digit");
}

@safe pure unittest
{
    import std.exception : assertThrown;

    assert(toHex([]) == "");
    assert(toHex([0x00, 0xab, 0x7f, 0xff]) == "00ab7fff");
    assert(fromHex("") == []);
    assert(fromHex("00aBfF") == [0x00, 0xab, 0xff]);
    assertThrown!InflateException(fromHex("abc"));
    assertThrown!InflateException(fromHex("zz"));
}
