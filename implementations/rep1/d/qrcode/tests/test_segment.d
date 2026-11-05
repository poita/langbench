module tests.test_segment;

import qrcode.segment;
import qrcode.tables;

private const(ubyte)[] b(string s) { return cast(const(ubyte)[]) s; }

unittest // mode selection
{
    assert(selectMode(b("0123456789")) == Mode.numeric);
    assert(selectMode(b("HELLO WORLD")) == Mode.alphanumeric);
    assert(selectMode(b("$%*+-./:")) == Mode.alphanumeric);
    assert(selectMode(b("hello")) == Mode.byteMode);
    assert(selectMode(b("héllo")) == Mode.byteMode);
    assert(selectMode(b("12a")) == Mode.byteMode);
}

unittest
{
    assert(alphanumericValue('0') == 0);
    assert(alphanumericValue('A') == 10);
    assert(alphanumericValue(' ') == 36);
    assert(alphanumericValue(':') == 44);
    assert(alphanumericValue('a') == -1);
}

unittest // bit lengths
{
    assert(dataBitLength(Mode.numeric, 8) == 27);
    assert(dataBitLength(Mode.numeric, 7) == 24);
    assert(dataBitLength(Mode.alphanumeric, 11) == 61);
    assert(dataBitLength(Mode.byteMode, 6) == 48);
    assert(charCountBits(Mode.byteMode, 9) == 8);
    assert(charCountBits(Mode.byteMode, 10) == 16);
    assert(charCountBits(Mode.numeric, 27) == 14);
}

unittest // version selection at capacity edges
{
    assert(selectVersion(Mode.numeric, 41, Ecl.L) == 1);
    assert(selectVersion(Mode.numeric, 42, Ecl.L) == 2);
    assert(selectVersion(Mode.alphanumeric, 25, Ecl.L) == 1);
    assert(selectVersion(Mode.alphanumeric, 26, Ecl.L) == 2);
    assert(selectVersion(Mode.byteMode, 17, Ecl.L) == 1);
    assert(selectVersion(Mode.byteMode, 18, Ecl.L) == 2);
    assert(selectVersion(Mode.numeric, 7089, Ecl.L) == 40);
    assert(selectVersion(Mode.numeric, 7090, Ecl.L) == -1);
    assert(selectVersion(Mode.alphanumeric, 4296, Ecl.L) == 40);
    assert(selectVersion(Mode.byteMode, 2953, Ecl.L) == 40);
    assert(selectVersion(Mode.byteMode, 1273, Ecl.H) == 40);
    assert(selectVersion(Mode.numeric, 3057, Ecl.H) == 40);
}

unittest // the spec's HELLO WORLD data codewords
{
    immutable ubyte[] expected = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17];
    assert(packData(b("HELLO WORLD"), Mode.alphanumeric, 1, Ecl.M) == expected);
}

unittest // numeric packing: "01234567" -> 0001 0000001000 0000001100 0101011 0011 1 ...
{
    auto d = packData(b("01234567"), Mode.numeric, 1, Ecl.L);
    assert(d.length == 19);
    assert(d[0] == 0x10 && d[1] == 0x20 && d[2] == 0x0C);
    assert(d[$ - 1] == 0xEC || d[$ - 1] == 0x11);
}

unittest // terminator is truncated when the stream exactly fills capacity
{
    // v1-H: 9 codewords = 72 bits; byte mode needs 12 + 8n bits, so n = 7 -> 68 bits.
    auto d = packData(b("abcdefg"), Mode.byteMode, 1, Ecl.H);
    assert(d.length == 9);
}
