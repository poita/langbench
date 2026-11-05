module test_coord;

import rubiks.coord;
import rubiks.cubie;
import rubiks.movetables;
import rubiks.moves;
import support;

unittest // Lehmer ranking
{
    ubyte[8] p;
    bool[] seen = new bool[numCornerPerms];
    foreach (r; 0 .. numCornerPerms)
    {
        unrankPerm(r, p[]);
        assert(isPermutation(p[]));
        assert(rankPerm(p[]) == r);
        seen[r] = true;
    }
    ubyte[4] q;
    foreach (r; 0 .. 24)
    {
        unrankPerm(r, q[]);
        assert(rankPerm(q[]) == r);
    }
    unrankPerm(0, p[]);
    assert(p == [0, 1, 2, 3, 4, 5, 6, 7]);
}

unittest // subset ranking
{
    foreach (r; 0 .. 495)
        assert(subsets12.rank[subsets12.masks[r]] == r);
    foreach (r; 0 .. 70)
        assert(subsets8.rank[subsets8.masks[r]] == r);
    assert(subsets12.rank[0xF00] != ushort.max);
    assert(subsets8.rank[0xAA] != ushort.max);
    assert(subsets12.rank[0x7] == ushort.max);
}

unittest // corner groups
{
    auto g = new CornerGroup;
    assert(g.halfPerms.length == numHalfCorners);
    assert(g.classRep.length == numCornerClasses);
    assert(g.halfIndex[0] == 0);
    uint inGroup;
    foreach (v; g.halfIndex)
        if (v != ubyte.max)
            ++inGroup;
    assert(inGroup == 96);
    // The identity's class is exactly the group.
    foreach (r; 0 .. numCornerPerms)
        assert((g.classOf[r] == g.classOf[0]) == (g.halfIndex[r] != ubyte.max));
    // Every class has 96 members.
    auto count = new uint[numCornerClasses];
    foreach (c; g.classOf)
        ++count[c];
    foreach (n; count)
        assert(n == 96);
}

unittest // solved cube coordinates
{
    CubieCube c;
    assert(flipCoord(c) == 0);
    assert(twistCoord(c) == 0);
    assert(sliceCoord(c) == subsets12.rank[0xF00]);
    assert(mSliceCoord(c) == subsets8.rank[0xAA]);
}

unittest // move tables agree with moving the cube and re-encoding
{
    import std.random : Mt19937;

    auto mt = new MoveTables;
    auto rng = Mt19937(7);
    foreach (trial; 0 .. 300)
    {
        CubieCube c;
        c.apply(randomScramble(rng, 30));
        foreach (m; 0 .. numMoves)
        {
            CubieCube n = c;
            n.apply(Move.fromId(m));
            assert(mt.flip[flipCoord(c) * numMoves + m] == flipCoord(n));
            assert(mt.twist[twistCoord(c) * numMoves + m] == twistCoord(n));
            assert(mt.slice[sliceCoord(c) * numMoves + m] == sliceCoord(n));
            assert(mt.cornerClass[mt.corners.classOf[rankPerm(c.cp[])] * numMoves + m]
                == mt.corners.classOf[rankPerm(n.cp[])]);
        }
    }
}

unittest // phase 3/4 tables on cubes in G2 / G3
{
    import std.random : Mt19937, uniform;

    auto mt = new MoveTables;
    auto rng = Mt19937(99);
    // G2 = <U, D, L2, R2, F2, B2>
    immutable uint[] g2 = [0, 1, 2, 9, 10, 11, 13, 4, 7, 16];
    foreach (trial; 0 .. 200)
    {
        CubieCube c;
        foreach (i; 0 .. 40)
            c.apply(Move.fromId(g2[uniform(0, g2.length, rng)]));
        foreach (m; g2)
        {
            if (Move.fromId(m).face == Face.F || Move.fromId(m).face == Face.B)
                continue;
            CubieCube n = c;
            n.apply(Move.fromId(m));
            if (Move.fromId(m).turns == 2 || Move.fromId(m).face == Face.U || Move.fromId(m).face == Face.D)
                assert(mt.mSlice[mSliceCoord(c) * numMoves + m] == mSliceCoord(n));
        }
    }
    // G3 = half turns
    foreach (trial; 0 .. 200)
    {
        CubieCube c;
        foreach (i; 0 .. 40)
            c.apply(Move.fromId(uniform(0, 6, rng) * 3 + 1));
        const h = mt.corners.halfIndex[rankPerm(c.cp[])];
        assert(h != ubyte.max);
        foreach (f; 0 .. 6)
        {
            const m = f * 3 + 1;
            CubieCube n = c;
            n.apply(Move.fromId(m));
            assert(mt.cornerHalf[h * numMoves + m] == mt.corners.halfIndex[rankPerm(n.cp[])]);
            foreach (s; 0 .. 3)
                assert(mt.slicePerm[s][slicePermCoord(c, s) * numMoves + m] == slicePermCoord(n, s));
        }
    }
}
