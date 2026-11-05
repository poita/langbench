module tests.adler32_test;

import mime.adler32;
import mime.buffer;

unittest
{
    assert(adler32([]) == 1);
    assert(adler32(cast(const(ubyte)[]) "Wikipedia") == 0x11E60398);
    assert(adler32([0, 1, 2, 3]) == 0x000e0007);
}

unittest // deferred modulo agrees with the per-byte definition
{
    auto data = new ubyte[](20_000);
    foreach (i, ref x; data)
        x = cast(ubyte)(255 - i % 7);
    uint a = 1, bb = 0;
    foreach (x; data)
    {
        a = (a + x) % 65_521;
        bb = (bb + a) % 65_521;
    }
    assert(adler32(data) == (bb << 16 | a));
}

unittest // hex formatting
{
    ByteBuffer o;
    o.putHex32(0x04680214);
    assert(o.toString() == "04680214");
}
