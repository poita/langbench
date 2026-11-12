/**
 * Hexadecimal helpers and the `<hex>` argument encoding of the command
 * protocol.
 *
 * Bytes are written as an even number of lowercase hex digits; the empty byte
 * string is written as the single character `-` so that a field is never
 * zero-length.
 */
module webhooks.hex;

private immutable char[16] hexDigits = "0123456789abcdef";

/// Lowercase hex of `data` (the empty string for empty input).
string toHex(scope const(ubyte)[] data) pure nothrow @safe
{
    auto result = new char[data.length * 2];
    foreach (i, b; data)
    {
        result[2 * i] = hexDigits[b >> 4];
        result[2 * i + 1] = hexDigits[b & 15];
    }
    return (() @trusted => cast(string) result)();
}

/// Like `toHex`, but returns `"-"` for empty input (the protocol encoding).
string toHexField(scope const(ubyte)[] data) pure nothrow @safe
{
    return data.length == 0 ? "-" : toHex(data);
}

private int nibble(ubyte c) pure nothrow @safe @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return -1;
}

/**
 * Decodes a protocol `<hex>` field: `-` for no bytes, otherwise an even number
 * of lowercase hex digits.
 *
 * Returns: `true` and fills `result` on success; `false` for an empty field,
 * odd length, uppercase digits or any other character.
 */
bool parseHexField(scope const(ubyte)[] field, out ubyte[] result) pure nothrow @safe
{
    if (field.length == 0)
        return false;
    if (field.length == 1 && field[0] == '-')
    {
        result = [];
        return true;
    }
    if (field.length % 2 != 0)
        return false;
    auto bytes = new ubyte[field.length / 2];
    foreach (i; 0 .. bytes.length)
    {
        immutable hi = nibble(field[2 * i]);
        immutable lo = nibble(field[2 * i + 1]);
        if (hi < 0 || lo < 0)
            return false;
        bytes[i] = cast(ubyte)(hi << 4 | lo);
    }
    result = bytes;
    return true;
}

@safe unittest
{
    assert(toHex([0x00, 0xab, 0xff]) == "00abff");
    assert(toHex([]) == "");
    assert(toHexField([]) == "-");
    assert(toHexField([1]) == "01");
}

@safe unittest
{
    ubyte[] r;
    assert(parseHexField(cast(const(ubyte)[]) "-", r) && r.length == 0);
    assert(parseHexField(cast(const(ubyte)[]) "00ff7a", r) && r == [0, 255, 0x7a]);
    assert(!parseHexField(cast(const(ubyte)[]) "", r));
    assert(!parseHexField(cast(const(ubyte)[]) "abc", r));
    assert(!parseHexField(cast(const(ubyte)[]) "ABCD", r));
    assert(!parseHexField(cast(const(ubyte)[]) "zz", r));
    assert(!parseHexField(cast(const(ubyte)[]) "--", r));
}
