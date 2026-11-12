/**
 * Bitboard helpers and precomputed attack tables.
 *
 * Leaper (knight, king, pawn) attacks are plain table lookups. Sliders use
 * classical ray attacks: the ray from the origin is cut at the first blocker
 * found with a bit scan. All tables are built at compile time.
 */
module chessperft.bitboard;

import core.bitop : bsf, bsr, popcnt;
import chessperft.types;

@safe pure nothrow @nogc:

/// The bitboard containing only `sq`.
Bitboard bit(int sq)
{
    return 1UL << sq;
}

/// Number of set bits.
int popCount(Bitboard b) @trusted
{
    return popcnt(b);
}

/// Index of the lowest set bit. `b` must be non-zero.
int lsb(Bitboard b) @trusted
{
    return bsf(b);
}

/// Removes and returns the lowest set bit's index. `b` must be non-zero.
int popLsb(ref Bitboard b) @trusted
{
    const s = bsf(b);
    b &= b - 1;
    return s;
}

/// Bitboard of all squares on a given zero-based rank.
Bitboard rankMask(int rank)
{
    return 0xFFUL << (rank * 8);
}

/// Bitboard of all squares on a given zero-based file.
Bitboard fileMask(int file)
{
    return 0x0101010101010101UL << file;
}

/// Ray directions: N, NE, E, SE, S, SW, W, NW.
private enum Dir : int { n, ne, e, se, s, sw, w, nw }
private immutable int[8] dirFile = [0, 1, 1, 1, 0, -1, -1, -1];
private immutable int[8] dirRank = [1, 1, 0, -1, -1, -1, 0, 1];

/// Precomputed lookup tables.
struct Tables
{
    /// Knight attacks from each square.
    Bitboard[64] knight;
    /// King attacks from each square.
    Bitboard[64] king;
    /// `pawn[c][sq]`: squares attacked by a pawn of colour `c` on `sq`.
    Bitboard[64][2] pawn;
    /// `ray[d][sq]`: squares from `sq` to the board edge in direction `d`, exclusive of `sq`.
    Bitboard[64][8] ray;
    /// `between[a][b]`: squares strictly between `a` and `b` when aligned, else 0.
    Bitboard[64][64] between;
    /// `line[a][b]`: the whole rank/file/diagonal through `a` and `b` when aligned, else 0.
    Bitboard[64][64] line;
}

private bool onBoard(int f, int r)
{
    return f >= 0 && f < 8 && r >= 0 && r < 8;
}

private Tables buildTables()
{
    Tables t;
    static immutable int[2][8] knightSteps =
        [[1, 2], [2, 1], [2, -1], [1, -2], [-1, -2], [-2, -1], [-2, 1], [-1, 2]];
    foreach (sq; 0 .. 64)
    {
        const f = fileOf(sq), r = rankOf(sq);
        foreach (s; knightSteps)
            if (onBoard(f + s[0], r + s[1]))
                t.knight[sq] |= bit(makeSquare(f + s[0], r + s[1]));
        foreach (d; 0 .. 8)
        {
            if (onBoard(f + dirFile[d], r + dirRank[d]))
                t.king[sq] |= bit(makeSquare(f + dirFile[d], r + dirRank[d]));
            // Walk the ray.
            int cf = f + dirFile[d], cr = r + dirRank[d];
            while (onBoard(cf, cr))
            {
                t.ray[d][sq] |= bit(makeSquare(cf, cr));
                cf += dirFile[d];
                cr += dirRank[d];
            }
        }
        foreach (df; [-1, 1])
        {
            if (onBoard(f + df, r + 1))
                t.pawn[Color.white][sq] |= bit(makeSquare(f + df, r + 1));
            if (onBoard(f + df, r - 1))
                t.pawn[Color.black][sq] |= bit(makeSquare(f + df, r - 1));
        }
    }
    foreach (a; 0 .. 64)
        foreach (d; 0 .. 8)
        {
            const f = fileOf(a), r = rankOf(a);
            const full = t.ray[d][a] | t.ray[(d + 4) & 7][a] | bit(a);
            Bitboard seen = 0;
            int cf = f + dirFile[d], cr = r + dirRank[d];
            while (onBoard(cf, cr))
            {
                const b = makeSquare(cf, cr);
                t.between[a][b] = seen;
                t.line[a][b] = full;
                seen |= bit(b);
                cf += dirFile[d];
                cr += dirRank[d];
            }
        }
    return t;
}

/// The lookup tables, computed at compile time.
immutable Tables tables = buildTables();

private bool positiveDir(int d)
{
    return d == Dir.n || d == Dir.ne || d == Dir.e || d == Dir.nw;
}

private Bitboard rayAttacks(int d, int sq, Bitboard occ)
{
    Bitboard r = tables.ray[d][sq];
    const blockers = r & occ;
    if (blockers)
    {
        const b = positiveDir(d) ? lsb(blockers) : msb(blockers);
        r ^= tables.ray[d][b];
    }
    return r;
}

private int msb(Bitboard b) @trusted
{
    return bsr(b);
}

/// Squares a knight on `sq` attacks.
Bitboard knightAttacks(int sq)
{
    return tables.knight[sq];
}

/// Squares a king on `sq` attacks.
Bitboard kingAttacks(int sq)
{
    return tables.king[sq];
}

/// Squares a pawn of colour `c` on `sq` attacks.
Bitboard pawnAttacks(Color c, int sq)
{
    return tables.pawn[c][sq];
}

/// Squares a bishop on `sq` attacks given occupancy `occ` (blockers included).
Bitboard bishopAttacks(int sq, Bitboard occ)
{
    return rayAttacks(Dir.ne, sq, occ) | rayAttacks(Dir.se, sq, occ)
        | rayAttacks(Dir.sw, sq, occ) | rayAttacks(Dir.nw, sq, occ);
}

/// Squares a rook on `sq` attacks given occupancy `occ` (blockers included).
Bitboard rookAttacks(int sq, Bitboard occ)
{
    return rayAttacks(Dir.n, sq, occ) | rayAttacks(Dir.e, sq, occ)
        | rayAttacks(Dir.s, sq, occ) | rayAttacks(Dir.w, sq, occ);
}

/// Squares a queen on `sq` attacks given occupancy `occ`.
Bitboard queenAttacks(int sq, Bitboard occ)
{
    return bishopAttacks(sq, occ) | rookAttacks(sq, occ);
}

/// Squares strictly between `a` and `b` if they share a line, else 0.
Bitboard between(int a, int b)
{
    return tables.between[a][b];
}

/// The full line through `a` and `b` if they share one, else 0.
Bitboard line(int a, int b)
{
    return tables.line[a][b];
}

/// Rook rays from `sq` on an empty board, excluding `sq`.
Bitboard rookRays(int sq)
{
    return tables.ray[Dir.n][sq] | tables.ray[Dir.e][sq] | tables.ray[Dir.s][sq] | tables.ray[Dir.w][sq];
}

/// Bishop rays from `sq` on an empty board, excluding `sq`.
Bitboard bishopRays(int sq)
{
    return tables.ray[Dir.ne][sq] | tables.ray[Dir.se][sq] | tables.ray[Dir.sw][sq] | tables.ray[Dir.nw][sq];
}

unittest
{
    assert(popCount(knightAttacks(0)) == 2);
    assert(popCount(knightAttacks(makeSquare(3, 3))) == 8);
    assert(popCount(kingAttacks(0)) == 3);
    assert(popCount(kingAttacks(makeSquare(4, 4))) == 8);
    assert(pawnAttacks(Color.white, makeSquare(4, 1)) == (bit(makeSquare(3, 2)) | bit(makeSquare(5, 2))));
    assert(pawnAttacks(Color.white, makeSquare(0, 1)) == bit(makeSquare(1, 2)));
    assert(pawnAttacks(Color.black, makeSquare(7, 6)) == bit(makeSquare(6, 5)));
    assert(pawnAttacks(Color.white, makeSquare(0, 7)) == 0);
}

unittest
{
    // Rook on an empty board always attacks 14 squares.
    foreach (sq; 0 .. 64)
        assert(popCount(rookAttacks(sq, 0)) == 14);
    // Blockers stop the ray and are included.
    const d4 = makeSquare(3, 3);
    const occ = bit(makeSquare(3, 5)) | bit(makeSquare(1, 3));
    const a = rookAttacks(d4, occ);
    assert(a & bit(makeSquare(3, 5)));
    assert(!(a & bit(makeSquare(3, 6))));
    assert(a & bit(makeSquare(1, 3)));
    assert(!(a & bit(makeSquare(0, 3))));
    assert(a & bit(makeSquare(7, 3)));
    assert(a & bit(makeSquare(3, 0)));
    // Bishop in the corner.
    assert(popCount(bishopAttacks(0, 0)) == 7);
    assert(popCount(bishopAttacks(0, bit(makeSquare(3, 3)))) == 3);
    assert(popCount(queenAttacks(d4, 0)) == 27);
}

unittest
{
    const a1 = makeSquare(0, 0), a8 = makeSquare(0, 7), h8 = makeSquare(7, 7);
    assert(popCount(between(a1, a8)) == 6);
    assert(popCount(between(a1, h8)) == 6);
    assert(between(a1, makeSquare(1, 2)) == 0);
    assert(line(a1, makeSquare(1, 2)) == 0);
    assert(popCount(line(makeSquare(2, 2), makeSquare(3, 3))) == 8);
    assert(line(a1, a8) == fileMask(0));
    assert(line(makeSquare(3, 4), makeSquare(6, 4)) == rankMask(4));
}
