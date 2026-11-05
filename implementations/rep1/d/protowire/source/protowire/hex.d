/**
 * Hexadecimal conversion (lowercase only).
 */
module protowire.hex;

import protowire.memory : ByteBuffer;

private immutable ubyte[256] nibbleTable = () {
    ubyte[256] t;
    t[] = 0xff;
    foreach (i; 0 .. 10)
        t['0' + i] = cast(ubyte) i;
    foreach (i; 0 .. 6)
        t['a' + i] = cast(ubyte)(10 + i);
    return t;
}();

/**
 * Decode a string of lowercase hex digits and append the bytes to `output`.
 *
 * Returns false (appending nothing) if `hex` has odd length or contains
 * anything other than `0-9a-f`.
 */
bool hexDecode(const(ubyte)[] hex, ref ByteBuffer output) nothrow @nogc @trusted
{
    if (hex.length & 1)
        return false;
    const n = hex.length / 2;
    output.reserve(n);
    ubyte* d = output.tail;
    const(ubyte)* s = hex.ptr;
    ubyte acc = 0;
    foreach (i; 0 .. n)
    {
        const hi = nibbleTable[s[2 * i]];
        const lo = nibbleTable[s[2 * i + 1]];
        acc |= hi | lo;
        d[i] = cast(ubyte)((hi << 4) | (lo & 15));
    }
    if (acc > 15)
        return false;
    output.advance(n);
    return true;
}

/// Value of one lowercase hex digit, or -1.
int hexDigitValue(ubyte c) pure nothrow @nogc @safe
{
    const v = nibbleTable[c];
    return v == 0xff ? -1 : v;
}
