/**
 * Hex argument decoding as used by the command protocol.
 *
 * A hex argument is an even number of lowercase hex digits, or the single
 * character `-` standing for the empty byte string.
 */
module webhooks.hex;

private immutable ubyte[256] digitValue = () {
    ubyte[256] t;
    t[] = 0xff;
    foreach (i; 0 .. 10)
        t['0' + i] = cast(ubyte) i;
    foreach (i; 0 .. 6)
        t['a' + i] = cast(ubyte)(10 + i);
    return t;
}();

/**
 * Decodes a protocol hex argument.
 *
 * Params:
 *   field = the argument text; `-` means "no bytes"
 *   bytes = receives the decoded bytes (empty on failure)
 * Returns: `false` if the field is empty, has an odd digit count, or contains
 *   anything but lowercase hex digits.
 */
bool decodeHex(scope const(ubyte)[] field, out ubyte[] bytes) @safe pure nothrow
{
    if (field.length == 0)
        return false;
    if (field.length == 1 && field[0] == '-')
        return true;
    if (field.length & 1)
        return false;
    auto result = new ubyte[field.length / 2];
    foreach (i; 0 .. result.length)
    {
        immutable hi = digitValue[field[2 * i]];
        immutable lo = digitValue[field[2 * i + 1]];
        if ((hi | lo) > 15)
            return false;
        result[i] = cast(ubyte)((hi << 4) | lo);
    }
    bytes = result;
    return true;
}

/// Lowercase hex of `bytes` (empty string for no bytes; no `-` substitution).
string toHex(scope const(ubyte)[] bytes) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    auto s = new char[bytes.length * 2];
    foreach (i, b; bytes)
    {
        s[2 * i] = digits[b >> 4];
        s[2 * i + 1] = digits[b & 15];
    }
    return (() @trusted => cast(string) s)();
}
