/**
 * Hexadecimal argument encoding used by the command language.
 *
 * Bytes are written as an even number of lowercase hex digits; the empty byte
 * string is written as the single character `-`.
 */
module webhooks.hex;

import webhooks.buffer;

private immutable string digits = "0123456789abcdef";

private ubyte[256] makeNibbleTable() @safe pure nothrow @nogc
{
    ubyte[256] t;
    t[] = 0xFF;
    foreach (i; 0 .. 10)
        t['0' + i] = cast(ubyte) i;
    foreach (i; 0 .. 6)
        t['a' + i] = cast(ubyte)(10 + i);
    return t;
}

private static immutable ubyte[256] nibble = makeNibbleTable();

/**
 * Decode a hex argument.
 *
 * Params:
 *   field  = `-` or an even-length run of lowercase hex digits
 *   result = receives the decoded bytes (empty for `-`)
 * Returns: `false` if `field` is empty, has odd length, or holds a character
 *          that is not a lowercase hex digit.
 */
bool decodeHex(Bytes field, out ubyte[] result) @safe pure nothrow
{
    if (field.length == 0)
        return false;
    if (field.length == 1 && field[0] == '-')
        return true;
    if (field.length % 2 != 0)
        return false;
    auto buf = new ubyte[field.length / 2];
    foreach (i; 0 .. buf.length)
    {
        immutable hi = nibble[field[2 * i]];
        immutable lo = nibble[field[2 * i + 1]];
        if ((hi | lo) > 15)
            return false;
        buf[i] = cast(ubyte)(hi << 4 | lo);
    }
    result = buf;
    return true;
}

/// Append the lowercase hex digits of `data` to `output` (nothing for empty input).
void putHex(ref OutBuffer output, Bytes data) @safe pure nothrow
{
    output.reserve(data.length * 2);
    foreach (b; data)
    {
        output.put(cast(ubyte) digits[b >> 4]);
        output.put(cast(ubyte) digits[b & 15]);
    }
}

/// Append hex digits of `data`, or `-` when `data` is empty.
void putHexOrDash(ref OutBuffer output, Bytes data) @safe pure nothrow
{
    if (data.length == 0)
        output.put(cast(ubyte) '-');
    else
        putHex(output, data);
}

/// Lowercase hex string of `data` (empty string for empty input).
string toHex(Bytes data) @safe pure nothrow
{
    OutBuffer o;
    putHex(o, data);
    return o.toString();
}
