/// Unit tests for gitrepo.inflate and gitrepo.delta.
module unit.test_inflate;

import std.exception : assertThrown;

import gitrepo.delta;
import gitrepo.errors;
import gitrepo.inflate;

ubyte[] fromHex(string h)
{
    ubyte[] r;
    foreach (i; 0 .. h.length / 2)
    {
        ubyte v = 0;
        foreach (c; h[2 * i .. 2 * i + 2])
            v = cast(ubyte)(v * 16 + (c <= '9' ? c - '0' : c - 'a' + 10));
        r ~= v;
    }
    return r;
}

unittest
{
    // fixed Huffman block: zlib.compress(b"hello")
    auto inf = new Inflater;
    assert(inf.decompress(fromHex("789ccb48cdc9c90700062c0215")) == cast(ubyte[]) "hello");
}

unittest
{
    // stored block, followed by bytes that belong to "the next object"
    auto inf = new Inflater;
    auto z = fromHex("7801" ~ "01" ~ "0300" ~ "fcff" ~ "616263" ~ "00000000" ~ "deadbeef");
    assert(inf.decompress(z) == cast(ubyte[]) "abc");
}

unittest
{
    // dynamic Huffman block with back-references
    string text;
    foreach (i; 0 .. 40)
    {
        import std.conv : to;

        text ~= "line " ~ to!string(i) ~ ": the " ~ ["fox", "dog", "cat"][i % 3] ~ " jumps\n";
    }
    auto z = fromHex("78da75d24b0ac2401045d1b9abe82574d5ebafbb118d3fa2118ce0f2453209789dbec181a2ee78b90f216ec37c1ec2717a87ebebf6786ec6ef6acb7a984eebd59775bf9bd7ab50482864140a0a15858642e72b221266689833224612239991c24865a431d2f92b11113744dc1911238991cc4861a432d218e95c19872a2e557f52e556c5b18a6b15e72aee551cac7e8afd0097ab2a80");
    auto inf = new Inflater;
    assert(inf.decompress(z, 10) == cast(ubyte[]) text); // hint smaller than the output
    assert(inf.decompress(z, 100000) == cast(ubyte[]) text); // and larger
}

unittest
{
    auto inf = new Inflater;
    assertThrown!InflateError(inf.decompress([0x78]));
    assertThrown!InflateError(inf.decompress(fromHex("7800" ~ "00")));           // bad FCHECK
    assertThrown!InflateError(inf.decompress(fromHex("7820" ~ "0000")));         // (0x7820 % 31 != 0 as well)
    assertThrown!InflateError(inf.decompress(fromHex("789c" ~ "cb48cdc9")));      // truncated
    assertThrown!InflateError(inf.decompress(fromHex("789c" ~ "07")));            // block type 3
    assertThrown!InflateError(inf.decompress(fromHex("7801" ~ "01" ~ "0300" ~ "0000" ~ "616263"))); // LEN/NLEN
}

unittest
{
    // base "hello world", result "hello, hello world!"
    immutable base = cast(immutable(ubyte)[]) "hello world";
    // sizes 11 and 19; insert "hello, " (7); copy offset 0 size 11; insert "!"
    ubyte[] delta = [11, 19, 7, 'h', 'e', 'l', 'l', 'o', ',', ' ', 0x90, 11, 1, '!'];
    assert(applyDelta(base, delta) == cast(ubyte[]) "hello, hello world!");
    // copy size 0 means 0x10000
    auto big = new ubyte[0x10000];
    big[] = 7;
    assert(applyDelta(big, [0x80, 0x80, 0x04, 0x80, 0x80, 0x04, 0x80]) == big);
}

unittest
{
    immutable base = cast(immutable(ubyte)[]) "hello world";
    assertThrown!GitError(applyDelta(base, [11, 5, 0x90, 20]));     // copy past the end of the base
    assertThrown!GitError(applyDelta(base, [11, 5, 0x90, 3]));      // wrong result size
    assertThrown!GitError(applyDelta(base, [11, 5, 0]));            // opcode 0
    assertThrown!GitError(applyDelta(base, [11, 3, 5, 'a']));       // truncated insert
    assertThrown!GitError(applyDelta(base, [11, 2, 3, 'a', 'b', 'c'])); // output overflow
}
