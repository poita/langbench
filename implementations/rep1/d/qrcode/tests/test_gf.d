module tests.test_gf;

import qrcode.gf;

unittest
{
    assert(gfPow2(0) == 1);
    assert(gfPow2(1) == 2);
    assert(gfPow2(8) == 0x1D);
    assert(gfPow2(255) == 1);
}

unittest // multiplication agrees with carry-less multiplication mod 0x11D
{
    ubyte slow(ubyte a, ubyte b)
    {
        int r = 0;
        foreach (i; 0 .. 8)
            if ((b >> i) & 1)
                r ^= a << i;
        foreach_reverse (i; 8 .. 15)
            if ((r >> i) & 1)
                r ^= 0x11D << (i - 8);
        return cast(ubyte) r;
    }

    foreach (a; 0 .. 256)
        foreach (b; 0 .. 256)
            assert(gfMul(cast(ubyte) a, cast(ubyte) b) == slow(cast(ubyte) a, cast(ubyte) b));
}

unittest // the spec's HELLO WORLD v1-M example
{
    immutable ubyte[] data = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17];
    immutable ubyte[] expected = [196, 35, 39, 119, 235, 215, 231, 226, 93, 23];
    auto ecc = new ubyte[10];
    rsRemainder(data, rsGenerator(10), ecc);
    assert(ecc == expected);
}

unittest // generator of degree 2 is (x+1)(x+2) = x^2 + 3x + 2
{
    assert(rsGenerator(2) == [3, 2]);
}
