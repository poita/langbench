module tests.test_encoder;

import std.algorithm : canFind, splitter;
import std.array : array, replicate;

import qrcode;
import qrcode.encoder : addEccAndInterleave;
import qrcode.penalty : penaltyScore;
import qrcode.tables : dataCodewords, totalCodewords;

private enum hello = "version 1 mask 0
#######...#.#.#######
#.....#.###...#.....#
#.###.#...#.#.#.###.#
#.###.#...#.#.#.###.#
#.###.#.#.###.#.###.#
#.....#..###..#.....#
#######.#.#.#.#######
.....................
#.#.#.#..#..#...#..#.
.####...#..#....#...#
...#######.#..#.##...
####.#.##..###.#.###.
.#..####.#.#..###.#.#
........#.#...#...#.#
#######.....#..#.##..
#.....#..##...##.#...
#.###.#.##..#.#######
#.###.#...##.#.#...#.
#.###.#.####.###.#..#
#.....#....###...#.##
#######.##.#.###....#

";

unittest // spec example 1
{
    assert(encode("HELLO WORLD", Ecl.M, 0).toText() == hello);
    // auto picks mask 0 here (penalties 311, 406, ...)
    assert(encode("HELLO WORLD", Ecl.M).toText() == hello);
}

unittest // spec example 2
{
    auto c = encode("01234567", Ecl.L);
    assert(c.version_ == 1 && c.mask == 3);
    auto lines = c.toText().splitter('\n').array;
    assert(lines[1] == "#######.##..#.#######");
    assert(lines[21] == "#######.##.##..#...#.");
}

unittest // spec example 3: UTF-8 payload in byte mode
{
    auto c = encode("héllo", Ecl.H, 5);
    assert(c.version_ == 1 && c.mask == 5);
    assert(c.toText().splitter('\n').array[1] == "#######.####..#######");
}

unittest // penalties for HELLO WORLD from the spec
{
    immutable int[8] expected = [311, 406, 442, 463, 367, 528, 395, 445];
    foreach (m; 0 .. 8)
    {
        auto c = encode("HELLO WORLD", Ecl.M, m);
        assert(penaltyScore(c.modules, c.size) == expected[m]);
    }
}

unittest // interleaving produces the right length and keeps data first for one block
{
    immutable ubyte[] data = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17];
    auto cw = addEccAndInterleave(data, 1, Ecl.M);
    assert(cw.length == 26);
    assert(cw[0 .. 16] == data);
    assert(cw[16 .. 18] == [196, 35]);
}

unittest // multi-block interleaving with short and long blocks (v5-Q: 2+2 blocks)
{
    enum ver = 5;
    auto data = new ubyte[dataCodewords(ver, Ecl.Q)];
    foreach (i, ref d; data)
        d = cast(ubyte) i;
    auto cw = addEccAndInterleave(data, ver, Ecl.Q);
    assert(cw.length == totalCodewords(ver));
    // blocks: 15,15,16,16 data codewords
    assert(cw[0] == 0 && cw[1] == 15 && cw[2] == 30 && cw[3] == 46);
    assert(cw[60] == 45 && cw[61] == 61); // last data position holds only the long blocks
}

unittest // sizes and capacities
{
    assert(encode("1".replicate(7089), Ecl.L).version_ == 40);
    assert(encode("A".replicate(4296), Ecl.L).version_ == 40);
    assert(encode("a".replicate(2953), Ecl.L).size == 177);
    assert(encode("a".replicate(1273), Ecl.H).version_ == 40);
    assert(encode("a".replicate(17), Ecl.L).version_ == 1);
    assert(encode("a".replicate(18), Ecl.L).version_ == 2);
}

unittest // errors
{
    import std.exception : assertThrown;
    assertThrown!QrException(encode("1".replicate(7090), Ecl.L));
    assertThrown!QrException(encode("a".replicate(1274), Ecl.H));
    assertThrown!QrException(encode("x", Ecl.L, 8));
}

unittest // auto mask equals the best fixed mask (lowest on ties)
{
    foreach (txt; ["hello world", "https://example.com/a/b?c=d", "0123456789012345678901234567890123456789"])
    {
        auto a = encode(txt, Ecl.Q);
        int best = int.max, bestMask = -1;
        foreach (m; 0 .. 8)
        {
            auto c = encode(txt, Ecl.Q, m);
            auto p = penaltyScore(c.modules, c.size);
            if (p < best)
            {
                best = p;
                bestMask = m;
            }
        }
        assert(a.mask == bestMask);
    }
}

unittest // isDark accessor and output shape
{
    auto c = encode("hi", Ecl.L, 2);
    assert(c.isDark(0, 0) && !c.isDark(7, 0));
    auto lines = c.toText().splitter('\n').array;
    assert(lines.length == 1 + 21 + 2); // header + rows + empty + trailing empty
    foreach (l; lines[1 .. 22])
        assert(l.length == 21);
}
