/// Lowercase hexadecimal conversion for byte strings.
module protowire.hex;

import std.array : Appender;
import protowire.errors : WireException;

private immutable char[16] digits = "0123456789abcdef";

/// Appends the lowercase hex of `bytes` to `sink`.
void appendHex(ref Appender!(char[]) sink, scope const(ubyte)[] bytes) @safe pure
{
    sink.reserve(bytes.length * 2);
    foreach (b; bytes)
    {
        sink.put(digits[b >> 4]);
        sink.put(digits[b & 15]);
    }
}

/// Lowercase hex of `bytes` (empty input gives an empty string).
string toHex(scope const(ubyte)[] bytes) @safe pure
{
    auto sink = Appender!(char[])();
    appendHex(sink, bytes);
    return (() @trusted => cast(string) sink.data)();
}

/// Value of a lowercase hex digit, or -1.
int hexDigitValue(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return -1;
}

/// Decodes a string of lowercase hex digits. Throws `WireException` on an odd
/// length or any character that is not `0-9a-f` (uppercase is rejected).
ubyte[] fromHex(scope const(char)[] hex) @safe pure
{
    if (hex.length & 1)
        throw new WireException("odd number of hex digits");
    auto result = new ubyte[hex.length / 2];
    foreach (i; 0 .. result.length)
    {
        immutable hi = hexDigitValue(hex[2 * i]);
        immutable lo = hexDigitValue(hex[2 * i + 1]);
        if (hi < 0 || lo < 0)
            throw new WireException("invalid hex digit");
        result[i] = cast(ubyte)((hi << 4) | lo);
    }
    return result;
}

@safe pure unittest
{
    assert(toHex([]) == "");
    assert(toHex([0x00, 0xff, 0x0a]) == "00ff0a");
    assert(fromHex("00ff0a") == [0x00, 0xff, 0x0a]);
    assert(fromHex("") == []);
}

@safe pure unittest
{
    import std.exception : assertThrown;

    assertThrown!WireException(fromHex("abc"));
    assertThrown!WireException(fromHex("AB"));
    assertThrown!WireException(fromHex("0g"));
    assertThrown!WireException(fromHex("0 "));
}
