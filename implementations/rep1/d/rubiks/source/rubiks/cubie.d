/**
 * The cubie-level cube model.
 *
 * A `CubieCube` records which corner and edge cubie sits at each position and
 * how it is twisted or flipped. Cubie moves are *derived* from the facelet
 * cycles of `rubiks.facelets` at compile time, so the facelet definition in
 * the specification is the single source of truth.
 *
 * Conventions
 * ---
 * Corner positions and cubies are numbered URF, UFL, ULB, UBR, DFR, DLF, DBL,
 * DRB (0-7); edges UR, UF, UL, UB, DR, DF, DL, DB, FR, FL, BL, BR (0-11).
 * `cp[i]` is the corner cubie at corner position `i` and `co[i]` its
 * orientation: the index (0, 1 or 2, clockwise) of the facelet of position `i`
 * that shows the cubie's first sticker (the U/D sticker). `ep[i]`/`eo[i]` are
 * the same for edges, where the first sticker is the one listed first in
 * `rubiks.facelets` and `eo[i]` is 0 or 1.
 *
 * With these conventions U, D, R and L preserve edge orientation, only F and
 * B quarter turns flip edges, and every quarter turn except U and D twists
 * corners.
 */
module rubiks.cubie;

import rubiks.facelets;
import rubiks.move;

/// A cube described by the placement and orientation of its cubies.
struct CubieCube
{
    /// Corner cubie at each corner position.
    ubyte[8] cp = [0, 1, 2, 3, 4, 5, 6, 7];
    /// Corner orientation (0..2) at each corner position.
    ubyte[8] co;
    /// Edge cubie at each edge position.
    ubyte[12] ep = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
    /// Edge orientation (0..1) at each edge position.
    ubyte[12] eo;

    /// The solved cube is the default value.
    static CubieCube solved() pure nothrow @safe @nogc
    {
        return CubieCube.init;
    }

    /// True if every cubie is in place and correctly oriented.
    bool isSolved() const pure nothrow @safe @nogc
    {
        return this == CubieCube.init;
    }

    /**
     * True if this describes a cube reachable by turning faces: both
     * permutations are valid, the corner twists sum to a multiple of 3, the
     * edge flips sum to an even number, and the two permutations have the
     * same parity.
     */
    bool isValid() const pure nothrow @safe @nogc
    {
        static bool parityOf(const(ubyte)[] p, out bool ok)
        {
            ulong seen;
            bool odd;
            foreach (i, v; p)
            {
                if (v >= p.length || (seen >> v) & 1)
                {
                    ok = false;
                    return false;
                }
                seen |= 1UL << v;
                foreach (j; i + 1 .. p.length)
                    odd ^= p[j] < v;
            }
            ok = true;
            return odd;
        }

        bool cornersOk, edgesOk;
        immutable cornerParity = parityOf(cp[], cornersOk);
        immutable edgeParity = parityOf(ep[], edgesOk);
        if (!cornersOk || !edgesOk || cornerParity != edgeParity)
            return false;
        int twist, flip;
        foreach (o; co)
        {
            if (o > 2)
                return false;
            twist += o;
        }
        foreach (o; eo)
        {
            if (o > 1)
                return false;
            flip += o;
        }
        return twist % 3 == 0 && flip % 2 == 0;
    }

    /// The state reached by applying `other` (as a move) to this state.
    CubieCube opBinary(string op : "*")(const ref CubieCube other) const pure nothrow @safe @nogc
    {
        CubieCube r;
        foreach (i; 0 .. 8)
        {
            immutable j = other.cp[i];
            r.cp[i] = cp[j];
            r.co[i] = cast(ubyte)((co[j] + other.co[i]) % 3);
        }
        foreach (i; 0 .. 12)
        {
            immutable j = other.ep[i];
            r.ep[i] = ep[j];
            r.eo[i] = cast(ubyte)(eo[j] ^ other.eo[i]);
        }
        return r;
    }

    /// Applies a move in place.
    void apply(Move m) pure nothrow @safe @nogc
    {
        this = this * basicMoves[m.id];
    }

    /// Applies a sequence of moves in place.
    void apply(const(Move)[] moves) pure nothrow @safe @nogc
    {
        foreach (m; moves)
            apply(m);
    }

    /// Returns the sticker colours (face indices) of this cube, one per facelet.
    ubyte[faceletCount] toFacelets() const pure nothrow @safe @nogc
    {
        ubyte[faceletCount] f;
        foreach (i; 0 .. 8)
            foreach (k; 0 .. 3)
                f[cornerFacelets[i][(k + co[i]) % 3]] = faceOf(cornerFacelets[cp[i]][k]);
        foreach (i; 0 .. 12)
            foreach (k; 0 .. 2)
                f[edgeFacelets[i][(k + eo[i]) % 2]] = faceOf(edgeFacelets[ep[i]][k]);
        foreach (face; 0 .. 6)
            f[face * 9 + 4] = cast(ubyte) face;
        return f;
    }

    /// Cubie-level cube obtained by applying `moves` to a solved cube.
    static CubieCube fromMoves(const(Move)[] moves) pure nothrow @safe @nogc
    {
        CubieCube c;
        c.apply(moves);
        return c;
    }
}

/// The cubie-level effect of each of the eighteen moves on a solved cube.
immutable CubieCube[moveCount] basicMoves = deriveBasicMoves();

private CubieCube deriveQuarterTurn(Face face) pure nothrow @safe @nogc
{
    immutable ubyte[faceletCount] src = faceletSource(Move(face, 1));
    CubieCube c;
    foreach (i; 0 .. 8)
    {
        // Colours now shown on the three facelets of corner position i.
        ubyte[3] col;
        foreach (k; 0 .. 3)
            col[k] = faceOf(src[cornerFacelets[i][k]]);
        foreach (j; 0 .. 8)
        {
            int matches;
            foreach (k; 0 .. 3)
                foreach (m; 0 .. 3)
                    if (col[k] == faceOf(cornerFacelets[j][m]))
                        ++matches;
            if (matches != 3)
                continue;
            c.cp[i] = cast(ubyte) j;
            foreach (k; 0 .. 3)
                if (col[k] == faceOf(cornerFacelets[j][0]))
                    c.co[i] = cast(ubyte) k;
        }
    }
    foreach (i; 0 .. 12)
    {
        ubyte[2] col;
        foreach (k; 0 .. 2)
            col[k] = faceOf(src[edgeFacelets[i][k]]);
        foreach (j; 0 .. 12)
        {
            immutable a = faceOf(edgeFacelets[j][0]);
            immutable b = faceOf(edgeFacelets[j][1]);
            if ((col[0] == a && col[1] == b) || (col[0] == b && col[1] == a))
            {
                c.ep[i] = cast(ubyte) j;
                c.eo[i] = col[0] == a ? 0 : 1;
            }
        }
    }
    return c;
}

private CubieCube[moveCount] deriveBasicMoves() pure nothrow @safe @nogc
{
    CubieCube[moveCount] r;
    foreach (face; 0 .. 6)
    {
        immutable one = deriveQuarterTurn(cast(Face) face);
        immutable two = one * one;
        r[face * 3] = one;
        r[face * 3 + 1] = two;
        r[face * 3 + 2] = two * one;
    }
    return r;
}

version (unittest)
{
    import std.random : Random, uniform;

    private Move[] randomMoves(ref Random rng, size_t n)
    {
        auto r = new Move[n];
        foreach (ref m; r)
            m = Move(uniform(0, moveCount, rng));
        return r;
    }
}

unittest
{
    // The cubie model agrees with the facelet model on random sequences.
    auto rng = Random(12345);
    foreach (_; 0 .. 200)
    {
        auto moves = randomMoves(rng, uniform(0, 60, rng));
        auto facelets = solvedFacelets;
        foreach (m; moves)
            applyToFacelets(facelets, m);
        assert(CubieCube.fromMoves(moves).toFacelets == facelets);
    }
}

@safe pure nothrow @nogc unittest
{
    assert(CubieCube.solved.isValid);
    foreach (m; allMoves)
        assert(basicMoves[m.id].isValid);
    CubieCube twisted;
    twisted.co[0] = 1;
    assert(!twisted.isValid);
    CubieCube flipped;
    flipped.eo[3] = 1;
    assert(!flipped.isValid);
    CubieCube swapped; // two edges exchanged: parity mismatch
    swapped.ep[0] = 1;
    swapped.ep[1] = 0;
    assert(!swapped.isValid);
    CubieCube duplicate;
    duplicate.cp[1] = 0;
    assert(!duplicate.isValid);
    assert(CubieCube.solved.isSolved);
    assert(CubieCube.solved.toFacelets == solvedFacelets);
    // X applied four times is the identity.
    foreach (m; allMoves)
    {
        auto c = CubieCube.solved;
        foreach (_; 0 .. 4)
            c.apply(Move(m.face, 1));
        assert(c.isSolved);
        assert(!basicMoves[m.id].isSolved);
    }
}

@safe pure unittest
{
    // Orientation behaviour: only F and B quarter turns flip edges; U and D
    // are the only moves that do not twist corners.
    foreach (m; allMoves)
    {
        immutable c = basicMoves[m.id];
        int flipped, twisted;
        foreach (e; c.eo)
            flipped += e;
        foreach (o; c.co)
            twisted += o != 0;
        immutable quarterFB = (m.face == Face.F || m.face == Face.B) && !m.isHalfTurn;
        assert(flipped == (quarterFB ? 4 : 0));
        immutable udOrHalf = m.face == Face.U || m.face == Face.D || m.isHalfTurn;
        assert(twisted == (udOrHalf ? 0 : 4));
    }
}

unittest
{
    import std.conv : to;

    // Order of move sequences, from the specification's sanity checks.
    size_t order(string seq)
    {
        auto moves = parseMoves(seq);
        auto c = CubieCube.solved;
        foreach (n; 1 .. 1000)
        {
            c.apply(moves);
            if (c.isSolved)
                return n;
        }
        return 0;
    }

    assert(order("R U R' U'") == 6);
    assert(order("R U") == 105);
    assert(order("U D") == 4);
    assert(order("U") == 4);
}

unittest
{
    // The superflip: all corners solved, all edges in place but flipped.
    auto c = CubieCube.fromMoves(parseMoves("U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2"));
    assert(c.cp == CubieCube.init.cp && c.co == CubieCube.init.co);
    assert(c.ep == CubieCube.init.ep);
    foreach (e; c.eo)
        assert(e == 1);
}

unittest
{
    // A move followed by its inverse restores the cube.
    auto rng = Random(7);
    foreach (_; 0 .. 50)
    {
        auto moves = randomMoves(rng, 30);
        auto c = CubieCube.fromMoves(moves);
        c.apply(invertMoves(moves));
        assert(c.isSolved);
    }
}
