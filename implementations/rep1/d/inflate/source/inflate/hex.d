/// Bulk hexadecimal conversion helpers.
module inflate.hex;

import std.exception : basicExceptionCtors;

/// Thrown by `hexDecode` on a malformed hex string.
class HexException : Exception
{
    mixin basicExceptionCtors;
}

private immutable ubyte[256] hexValue = () {
    ubyte[256] t;
    t[] = 0xFF;
    foreach (i; 0 .. 10) t['0' + i] = cast(ubyte) i;
    foreach (i; 0 .. 6)
    {
        t['a' + i] = cast(ubyte)(10 + i);
        t['A' + i] = cast(ubyte)(10 + i);
    }
    return t;
}();

private immutable char[16] hexDigits = "0123456789abcdef";

/// 256 two-character entries, one per byte value.
private immutable char[512] hexPairs = () {
    char[512] t;
    foreach (i; 0 .. 256)
    {
        t[2 * i] = hexDigits[i >> 4];
        t[2 * i + 1] = hexDigits[i & 15];
    }
    return t;
}();

/**
 * Decodes hexadecimal text (either case, two digits per byte) into bytes.
 *
 * Throws: `HexException` if the length is odd or a non-hex character occurs.
 */
ubyte[] hexDecode(const(char)[] text) pure @safe
{
    import std.array : uninitializedArray;

    if (text.length & 1)
        throw new HexException("odd number of hex digits");
    auto result = uninitializedArray!(ubyte[])(text.length / 2);
    uint bad = 0;
    foreach (i, ref b; result)
    {
        immutable hi = hexValue[text[2 * i]];
        immutable lo = hexValue[text[2 * i + 1]];
        bad |= hi | lo;
        b = cast(ubyte)((hi << 4) | (lo & 15));
    }
    if (bad & 0xF0)
        throw new HexException("invalid hex digit");
    return result;
}

/**
 * Encodes `data` as lowercase hexadecimal, followed by `suffix` (default none),
 * into a single freshly allocated buffer.
 */
char[] hexEncode(const(ubyte)[] data, string suffix = "") pure nothrow @safe
{
    import std.array : uninitializedArray;

    auto result = uninitializedArray!(char[])(data.length * 2 + suffix.length);
    foreach (i, b; data)
    {
        result[2 * i .. 2 * i + 2] = hexPairs[2 * b .. 2 * b + 2];
    }
    result[data.length * 2 .. $] = suffix[];
    return result;
}
