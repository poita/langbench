module hex_test;

import webhooks.hex;

@("hex: decode and encode")
unittest
{
    ubyte[] r;
    assert(decodeHex(cast(const(ubyte)[]) "00ff7a", r) && r == [0x00, 0xff, 0x7a]);
    assert(toHex(r) == "00ff7a");
}

@("hex: rejects uppercase, odd length and junk")
unittest
{
    ubyte[] r;
    foreach (bad; ["AB", "abc", "zz", "a ", "-", ""])
        assert(!decodeHex(cast(const(ubyte)[]) bad, r), bad);
}

@("hex: '-' means empty in arguments")
unittest
{
    ubyte[] r = [1];
    assert(decodeHexArg(cast(const(ubyte)[]) "-", r) && r.length == 0);
    assert(!decodeHexArg(cast(const(ubyte)[]) "--", r));
}
