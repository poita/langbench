/// Unit tests for inflate.bitreader.
module bitreader_test;

import std.exception : assertThrown;

import inflate.bitreader;
import inflate.errors;

@safe unittest
{
    // 0xA5 = 1010 0101: bits are consumed from the least significant end.
    auto br = BitReader([0xA5, 0x0F]);
    assert(br.take(1) == 1);
    assert(br.take(2) == 2);        // bits 1,2 = 0,1 -> 0b10
    assert(br.take(5) == 0b10100);  // bits 3..7
    assert(br.take(8) == 0x0F);
    assert(br.atEnd);
}

@safe unittest
{
    auto br = BitReader([0xFF]);
    br.take(8);
    assertThrown!InflateException(br.take(1));
    // Peeking past the end is allowed and reads zeros.
    br = BitReader([0x01]);
    br.refill();
    br.drop(8);
    assert(br.peek(16) == 0);
}

@safe unittest
{
    // Long input exercises the 8-byte refill path.
    ubyte[] data;
    foreach (i; 0 .. 100) data ~= cast(ubyte) i;
    auto br = BitReader(data);
    foreach (i; 0 .. 100)
        assert(br.take(8) == i);
    assert(br.atEnd);
    assert(br.bitPosition == 800);
}

@safe unittest
{
    // Byte alignment and bulk byte access.
    auto br = BitReader([0x07, 0x11, 0x22, 0x33, 0x44]);
    br.take(3);
    br.alignToByte();
    assert(br.takeBytes(3) == [0x11, 0x22, 0x33]);
    assert(br.take(8) == 0x44);
    assert(br.atEnd);
    br = BitReader([1, 2]);
    assertThrown!InflateException(br.takeBytes(3));
}
