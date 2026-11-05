module test_facelet;

import rubiks.facelet;
import rubiks.moves;

private FaceletCube after(string moves)
{
    auto c = FaceletCube.solved();
    c.apply(parseMoves(moves));
    return c;
}

unittest // names
{
    assert(faceletIndex("U1") == 0);
    assert(faceletIndex("U9") == 8);
    assert(faceletIndex("R1") == 9);
    assert(faceletIndex("B9") == 53);
}

unittest // solved cube
{
    assert(FaceletCube.solved.isSolved);
    assert(FaceletCube.solved.toString ==
        "UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB");
    assert(FaceletCube.fromString(FaceletCube.solved.toString).isSolved);
}

unittest // example from the specification: U on a solved cube
{
    const c = after("U");
    foreach (i; 1 .. 4)
    {
        assert(c.stickers[faceletIndex("F1") + i - 1] == Face.R);
        assert(c.stickers[faceletIndex("L1") + i - 1] == Face.F);
        assert(c.stickers[faceletIndex("B1") + i - 1] == Face.L);
        assert(c.stickers[faceletIndex("R1") + i - 1] == Face.B);
    }
    assert(!c.isSolved);
}

unittest // four quarter turns, and X2 / X' consistency
{
    foreach (f; "URFDLB")
    {
        const s = [f];
        assert(after((s ~ " ") ~ s ~ " " ~ s ~ " " ~ s).isSolved);
        assert(after(s ~ " " ~ s) == after(s ~ "2"));
        assert(after(s ~ " " ~ s ~ " " ~ s) == after(s ~ "'"));
        assert(after(s ~ " " ~ s ~ "'").isSolved);
    }
}

unittest // orders given in the specification
{
    static size_t order(string seq)
    {
        auto c = FaceletCube.solved();
        const m = parseMoves(seq);
        size_t n;
        do
        {
            c.apply(m);
            ++n;
        }
        while (!c.isSolved);
        return n;
    }

    assert(order("R U R' U'") == 6);
    assert(order("R U") == 105);
    assert(order("U D") == 4);
}

unittest // superflip
{
    const c = after("U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2");
    // every corner sticker home, every edge sticker swapped with its partner
    foreach (i; 0 .. 8)
        foreach (k; 0 .. 3)
            assert(c.stickers[cornerFacelets[i][k]] == cornerFacelets[i][k] / 9);
    foreach (i; 0 .. 12)
    {
        assert(c.stickers[edgeFacelets[i][0]] == edgeFacelets[i][1] / 9);
        assert(c.stickers[edgeFacelets[i][1]] == edgeFacelets[i][0] / 9);
    }
    foreach (f; 0 .. 6)
        assert(c.stickers[f * 9 + 4] == f);
}

unittest // adjacency in the net: a U move carries R1..R3 to F1..F3
{
    const c = after("U");
    // sticker that was at R1 is now at F1
    assert(c.stickers[faceletIndex("F1")] == Face.R);
    assert(c.stickers[faceletIndex("U3")] == Face.U);
}
