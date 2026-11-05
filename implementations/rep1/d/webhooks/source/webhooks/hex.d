/**
 * Lowercase hexadecimal encoding/decoding with the `-` = empty convention
 * used by the command stream.
 */
module webhooks.hex;

import webhooks.buffer;

private immutable string digits = "0123456789abcdef";

private immutable ubyte[256] nibbleTable = () {
    ubyte[256] t;
    t[] = 0xff;
    foreach (i; 0 .. 10)
        t['0' + i] = cast(ubyte) i;
    foreach (i; 0 .. 6)
        t['a' + i] = cast(ubyte)(10 + i);
    return t;
}();

/// Decodes `text` (lowercase hex, even length) into a new buffer.
/// Returns false if `text` is not valid. The empty string is invalid here;
/// see `decodeHexArg` for the command-stream convention.
bool decodeHex(scope const(ubyte)[] text, out ubyte[] bytes) @safe pure nothrow
{
    if (text.length == 0 || text.length % 2 != 0)
        return false;
    auto result = new ubyte[text.length / 2];
    foreach (i; 0 .. result.length)
    {
        immutable hi = nibbleTable[text[2 * i]];
        immutable lo = nibbleTable[text[2 * i + 1]];
        if ((hi | lo) == 0xff)
            return false;
        result[i] = cast(ubyte)((hi << 4) | lo);
    }
    bytes = result;
    return true;
}

/// Decodes a `<hex>` argument: lowercase hex or the single character `-`
/// for the empty byte string.
bool decodeHexArg(scope const(ubyte)[] field, out ubyte[] bytes) @safe pure nothrow
{
    if (field.length == 1 && field[0] == '-')
    {
        bytes = null;
        return true;
    }
    return decodeHex(field, bytes);
}

/// Appends the lowercase hex of `data` to `sink`.
void encodeHex(scope const(ubyte)[] data, ref ByteSink sink) @safe pure nothrow
{
    sink.reserve(data.length * 2);
    foreach (b; data)
    {
        sink.put(cast(ubyte) digits[b >> 4]);
        sink.put(cast(ubyte) digits[b & 15]);
    }
}

/// Appends the lowercase hex of `data`, or `-` if it is empty.
void encodeHexArg(scope const(ubyte)[] data, ref ByteSink sink) @safe pure nothrow
{
    if (data.length == 0)
        sink.putChar('-');
    else
        encodeHex(data, sink);
}

/// Convenience: hex string of `data`.
string toHex(scope const(ubyte)[] data) @trusted pure nothrow
{
    ByteSink s;
    encodeHex(data, s);
    return cast(string) s.data.idup;
}
