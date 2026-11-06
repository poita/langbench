/// Unit tests for softfloat.io and softfloat.bits / softfloat.round.
module softfloat.io_test;

import softfloat;

private string run(string s)
{
    return cast(string) processBatch(cast(const(ubyte)[]) s);
}

unittest
{
    assert(run("add 3f800000 3f800000\nsqrt 40000000\n") == "40000000\n3fb504f3\n");
    assert(run("mul 40400000 c0400000") == "c1100000\n"); // no trailing newline
    assert(run("sub 3f800000 3f800000\r\ndiv 3f800000 40400000\r\n") == "00000000\n3eaaaaab\n");
    assert(run("sqrt 7f800000\nsqrt 80000000") == "7f800000\n80000000\n");
}

unittest
{
    assert(parseHex32(cast(const(ubyte)[]) "deadbeef") == 0xdeadbeef);
    ubyte[9] buf;
    formatHex32(0x0000abcd, buf[]);
    assert(cast(string) buf[] == "0000abcd\n");
    assert(execute(Op.add, 0x3f800000, 0x3f800000) == 0x40000000);
    assert(execute(Op.sqrt, 0x40800000) == 0x40000000);
}

unittest // bits
{
    assert(isNaN(0x7f800001) && isNaN(0xffffffff) && !isNaN(0x7f800000));
    assert(isInfinity(0xff800000) && !isInfinity(0x7f7fffff));
    assert(isZero(0x80000000) && !isZero(1));
    assert(unpack(0x3f800000) == Unpacked(0x800000, -23));
    assert(unpack(0x00000001) == Unpacked(1, -149));
    assert(unpackNormalized(0x00000001) == Unpacked(0x800000, -172));
}

unittest // roundPack
{
    assert(roundPack(false, 1UL << 23, -23, false) == 0x3f800000);
    assert(roundPack(false, (1UL << 24) + 1, -24, false) == 0x3f800000); // tie -> even
    assert(roundPack(false, (1UL << 24) + 1, -24, true) == 0x3f800001);  // above tie
    assert(roundPack(false, 1, -150, false) == 0);                       // half min denormal
    assert(roundPack(false, 0xffffff, -150, false) == 0x00800000);       // carry into normal
    assert(roundPack(true, 1UL << 23, 105, false) == 0xff800000);        // overflow
    assert(roundPack(false, ulong.max, -300, true) == 0);                // deep underflow
}
