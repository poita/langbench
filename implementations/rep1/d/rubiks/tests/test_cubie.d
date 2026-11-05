module test_cubie;

import std.random : Mt19937;

import rubiks.cubie;
import rubiks.facelet;
import rubiks.moves;
import support;

unittest // the solved cube
{
    CubieCube c;
    assert(c.isSolved);
    assert(c.isSolvable);
    assert(c.toFacelets.isSolved);
}

unittest // only quarter turns of F and B change edge orientation
{
    foreach (m; 0 .. numMoves)
    {
        const mv = Move.fromId(m);
        uint flips;
        foreach (v; moveCubes[m].eo)
            flips += v;
        const flipper = (mv.face == Face.F || mv.face == Face.B) && mv.turns != 2;
        assert(flips == (flipper ? 4 : 0), mv.toString);
        uint twists;
        foreach (v; moveCubes[m].co)
            twists += v;
        assert(twists % 3 == 0);
    }
}

unittest // a move cubie is a legal state, and inverse moves compose to identity
{
    foreach (m; 0 .. numMoves)
    {
        assert(moveCubes[m].isSolvable);
        CubieCube c = moveCubes[m];
        c.apply(Move.fromId(m).inverse);
        assert(c.isSolved);
    }
}

unittest // cubie moves agree with the facelet model on random sequences
{
    auto rng = Mt19937(12345);
    foreach (trial; 0 .. 200)
    {
        const moves = randomScramble(rng, 1 + trial % 40);
        CubieCube c;
        c.apply(moves);
        auto f = FaceletCube.solved();
        f.apply(moves);
        assert(c.toFacelets == f);
        assert(CubieCube.fromFacelets(f) == c);
        assert(c.isSolvable);
    }
}

unittest // solvability checks
{
    CubieCube c;
    c.co[0] = 1;                       // single twisted corner
    assert(!c.isSolvable);
    c = CubieCube.init;
    c.eo[3] = 1;                       // single flipped edge
    assert(!c.isSolvable);
    c = CubieCube.init;
    c.ep[0] = 1;                       // not a permutation
    assert(!c.isSolvable);
    c = CubieCube.init;
    c.ep[0] = 1;
    c.ep[1] = 0;                       // swapped edges only: parity mismatch
    assert(!c.isSolvable);
    c.cp[0] = 1;
    c.cp[1] = 0;                       // matching swapped corners: legal
    assert(c.isSolvable);
}

unittest // invalid sticker sets are rejected
{
    import std.exception : assertThrown;

    auto f = FaceletCube.solved();
    f.stickers[faceletIndex("U9")] = Face.D;
    assertThrown(CubieCube.fromFacelets(f));
}

unittest // permutation helpers
{
    ubyte[] id = [0, 1, 2, 3];
    ubyte[] swap = [1, 0, 2, 3];
    assert(isPermutation(id));
    assert(!isPermutation([0, 0, 1, 2]));
    assert(parity(id) == 0 && parity(swap) == 1);
}
