module hex_test;

import protowire.hex;
import protowire.memory;

private bool decodeHex(string s, ref ByteBuffer b) @trusted
{
    return hexDecode(cast(const(ubyte)[]) s, b);
}

@system unittest
{
    ByteBuffer b;
    assert(decodeHex("00ff7f10", b));
    assert(b.data == [0x00, 0xff, 0x7f, 0x10]);
    assert(decodeHex("", b));
    assert(b.length == 4);
}

@system unittest // rejects bad input and appends nothing
{
    ByteBuffer b;
    assert(!decodeHex("abc", b));
    assert(!decodeHex("AB", b));
    assert(!decodeHex("0g", b));
    assert(!decodeHex("00 ", b));
    assert(b.length == 0);
}

@system unittest // encoding
{
    ByteBuffer b;
    b.putHex([0x00, 0xab, 0xff]);
    assert(b.data == cast(const(ubyte)[]) "00abff");
}

@safe unittest
{
    assert(hexDigitValue('a') == 10 && hexDigitValue('9') == 9);
    assert(hexDigitValue('A') == -1 && hexDigitValue('g') == -1);
}
