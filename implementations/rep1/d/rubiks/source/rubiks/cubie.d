/**
 * Cubie-level cube representation: where each corner and edge piece is and
 * how it is oriented.
 *
 * Positions and pieces share one numbering (a piece's number is the position
 * it occupies when solved):
 *
 * $(UL
 *   $(LI corners 0-7: URF UFL ULB UBR DFR DLF DBL DRB)
 *   $(LI edges 0-3: UR UF UL UB, 4-7: DR DF DL DB, 8-11: FR FL BL BR)
 * )
 *
 * Corner orientation is the index (0, 1 or 2) within the position's facelet
 * triple of the piece's U/D sticker.  Edge orientation is 0 when the piece's
 * primary sticker (U/D colour, or F/B colour for middle-layer pieces) is on
 * the position's primary facelet.  With these conventions only quarter turns
 * of F and B change edge orientation.
 */
module rubiks.cubie;

import rubiks.facelet;
import rubiks.moves;

/// Positions of the middle-slice ("E slice") edges.
enum ubyte firstSliceEdge = 8;

/**
 * A cube state as four small arrays.  `cp[i]` / `co[i]` are the piece at
 * corner position `i` and its orientation; `ep` / `eo` likewise for edges.
 * The default value is the solved cube.
 */
struct CubieCube
{
    ubyte[8] cp = [0, 1, 2, 3, 4, 5, 6, 7];  /// corner piece at each position
    ubyte[8] co;                             /// corner orientation (0..2)
    ubyte[12] ep = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]; /// edge piece at each position
    ubyte[12] eo;                            /// edge orientation (0..1)

    /// Applies a move to this cube (a single 20-element composition).
    void apply(Move m) pure nothrow @safe @nogc
    {
        const mc = &moveCubes[m.id];
        ubyte[8] ncp = void, nco = void;
        ubyte[12] nep = void, neo = void;
        foreach (i; 0 .. 8)
        {
            const j = mc.cp[i];
            ncp[i] = cp[j];
            nco[i] = cast(ubyte)((co[j] + mc.co[i]) % 3);
        }
        foreach (i; 0 .. 12)
        {
            const j = mc.ep[i];
            nep[i] = ep[j];
            neo[i] = cast(ubyte)(eo[j] ^ mc.eo[i]);
        }
        cp = ncp;
        co = nco;
        ep = nep;
        eo = neo;
    }

    /// Applies a sequence of moves, left to right.
    void apply(const(Move)[] moves) pure nothrow @safe @nogc
    {
        foreach (m; moves)
            apply(m);
    }

    /// True for the solved cube.
    bool isSolved() const pure nothrow @safe @nogc
    {
        return this == CubieCube.init;
    }

    /**
     * Whether this state can be reached from the solved cube by legal
     * moves: pieces form permutations, the orientation sums are 0 mod 3 /
     * mod 2, and the two permutations have the same parity.
     */
    bool isSolvable() const pure nothrow @safe @nogc
    {
        if (!isPermutation(cp[]) || !isPermutation(ep[]))
            return false;
        uint ts, fs;
        foreach (v; co)
        {
            if (v > 2)
                return false;
            ts += v;
        }
        foreach (v; eo)
        {
            if (v > 1)
                return false;
            fs += v;
        }
        return ts % 3 == 0 && fs % 2 == 0 && parity(cp[]) == parity(ep[]);
    }

    /// Converts to the sticker representation.
    FaceletCube toFacelets() const pure nothrow @safe @nogc
    {
        auto f = FaceletCube.solved();
        foreach (i; 0 .. 8)
            foreach (k; 0 .. 3)
                f.stickers[cornerFacelets[i][(k + co[i]) % 3]] =
                    cast(Face)(cornerFacelets[cp[i]][k] / 9);
        foreach (i; 0 .. 12)
            foreach (k; 0 .. 2)
                f.stickers[edgeFacelets[i][(k + eo[i]) % 2]] =
                    cast(Face)(edgeFacelets[ep[i]][k] / 9);
        return f;
    }

    /// Converts from stickers; throws if the stickers do not describe a
    /// physically consistent set of pieces (the result may still be
    /// unsolvable; see `isSolvable`).
    static CubieCube fromFacelets(in FaceletCube f) pure @safe
    {
        CubieCube c;
        bool[8] seenC;
        bool[12] seenE;
        foreach (i; 0 .. 8)
        {
            Face[3] col;
            foreach (k; 0 .. 3)
                col[k] = f.stickers[cornerFacelets[i][k]];
            int k0 = -1;
            foreach (k; 0 .. 3)
                if (col[k] == Face.U || col[k] == Face.D)
                    k0 = k;
            if (k0 < 0)
                throw new Exception("corner without U/D sticker");
            int piece = -1;
            foreach (j; 0 .. 8)
                if (col[k0] == cornerFacelets[j][0] / 9
                    && col[(k0 + 1) % 3] == cornerFacelets[j][1] / 9
                    && col[(k0 + 2) % 3] == cornerFacelets[j][2] / 9)
                    piece = j;
            if (piece < 0 || seenC[piece])
                throw new Exception("invalid corner");
            seenC[piece] = true;
            c.cp[i] = cast(ubyte) piece;
            c.co[i] = cast(ubyte) k0;
        }
        foreach (i; 0 .. 12)
        {
            const a = f.stickers[edgeFacelets[i][0]];
            const b = f.stickers[edgeFacelets[i][1]];
            int piece = -1, flip;
            foreach (j; 0 .. 12)
            {
                const h0 = edgeFacelets[j][0] / 9;
                const h1 = edgeFacelets[j][1] / 9;
                if (a == h0 && b == h1)
                {
                    piece = j;
                    flip = 0;
                }
                else if (a == h1 && b == h0)
                {
                    piece = j;
                    flip = 1;
                }
            }
            if (piece < 0 || seenE[piece])
                throw new Exception("invalid edge");
            seenE[piece] = true;
            c.ep[i] = cast(ubyte) piece;
            c.eo[i] = cast(ubyte) flip;
        }
        return c;
    }
}

/// True if `p` contains each of `0 .. p.length` exactly once.
bool isPermutation(const(ubyte)[] p) pure nothrow @safe @nogc
{
    uint seen;
    foreach (v; p)
    {
        if (v >= p.length || (seen & (1u << v)))
            return false;
        seen |= 1u << v;
    }
    return true;
}

/// Parity (0 even, 1 odd) of a permutation, by counting inversions.
uint parity(const(ubyte)[] p) pure nothrow @safe @nogc
{
    uint inv;
    foreach (i; 0 .. p.length)
        foreach (j; i + 1 .. p.length)
            if (p[i] > p[j])
                ++inv;
    return inv & 1;
}

private CubieCube[numMoves] buildMoveCubes() pure @safe
{
    CubieCube[numMoves] all;
    foreach (m; 0 .. numMoves)
    {
        auto f = FaceletCube.solved();
        f.apply(Move.fromId(m));
        all[m] = CubieCube.fromFacelets(f);
    }
    return all;
}

/// The cubie state produced by each of the eighteen moves from the solved
/// cube, derived from the facelet cycles at compile time.
immutable CubieCube[numMoves] moveCubes = buildMoveCubes();

/// Returns a solved cube with `moves` applied.
CubieCube cubeFromMoves(const(Move)[] moves) pure nothrow @safe @nogc
{
    CubieCube c;
    c.apply(moves);
    return c;
}
