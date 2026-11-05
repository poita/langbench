/++
Precomputed attack tables.

All tables are built at compile time (CTFE) and stored as `immutable` data, so
there is no start-up cost. Sliders use *classical ray lookups*: the
ray in each direction from a square is masked off beyond the first blocker,
found with a single bit-scan.
+/
module chessperft.tables;

import chessperft.bitboard;
import chessperft.types;

/// The eight ray directions. North is towards rank 8, east towards the h-file.
enum Dir : int
{
    north = 0, northEast, east, southEast, south, southWest, west, northWest,
}

private immutable int[8] dirFile = [0, 1, 1, 1, 0, -1, -1, -1];
private immutable int[8] dirRank = [1, 1, 0, -1, -1, -1, 0, 1];

private Bitboard[64][8] buildRays() pure nothrow @safe
{
    Bitboard[64][8] r;
    foreach (d; 0 .. 8)
        foreach (sq; 0 .. 64)
        {
            int f = sq & 7, rk = sq >> 3;
            while (true)
            {
                f += dirFile[d];
                rk += dirRank[d];
                if (f < 0 || f > 7 || rk < 0 || rk > 7)
                    break;
                r[d][sq] |= 1UL << (rk * 8 + f);
            }
        }
    return r;
}

private Bitboard[64] buildLeaper(immutable int[] df, immutable int[] dr) pure nothrow @safe
{
    Bitboard[64] t;
    foreach (sq; 0 .. 64)
        foreach (i; 0 .. df.length)
        {
            int f = (sq & 7) + df[i], rk = (sq >> 3) + dr[i];
            if (f >= 0 && f <= 7 && rk >= 0 && rk <= 7)
                t[sq] |= 1UL << (rk * 8 + f);
        }
    return t;
}

private Bitboard[64][2] buildPawnAttacks() pure nothrow @safe
{
    Bitboard[64][2] t;
    foreach (sq; 0 .. 64)
    {
        int f = sq & 7, rk = sq >> 3;
        foreach (df; [-1, 1])
        {
            if (f + df < 0 || f + df > 7)
                continue;
            if (rk < 7)
                t[Color.white][sq] |= 1UL << ((rk + 1) * 8 + f + df);
            if (rk > 0)
                t[Color.black][sq] |= 1UL << ((rk - 1) * 8 + f + df);
        }
    }
    return t;
}

private Bitboard[64][64] buildBetween() pure nothrow @safe
{
    Bitboard[64][64] t;
    foreach (a; 0 .. 64)
        foreach (d; 0 .. 8)
        {
            immutable opp = (d + 4) & 7;
            foreach (b; 0 .. 64)
                if (rays[d][a] & (1UL << b))
                    t[a][b] = rays[d][a] & rays[opp][b];
        }
    return t;
}

private Bitboard[64][64] buildLine() pure nothrow @safe
{
    Bitboard[64][64] t;
    foreach (a; 0 .. 64)
        foreach (d; 0 .. 8)
        {
            immutable opp = (d + 4) & 7;
            foreach (b; 0 .. 64)
                if (rays[d][a] & (1UL << b))
                    t[a][b] = rays[d][a] | rays[opp][a] | (1UL << a);
        }
    return t;
}

/// `rays[d][sq]`: squares strictly beyond `sq` in direction `d` on an empty board.
immutable Bitboard[64][8] rays = buildRays();

/// Knight attack set per square.
immutable Bitboard[64] knightAttacks = buildLeaper([1, 2, 2, 1, -1, -2, -2, -1], [2, 1, -1, -2, -2, -1, 1, 2]);

/// King attack set per square.
immutable Bitboard[64] kingAttacks = buildLeaper([0, 1, 1, 1, 0, -1, -1, -1], [1, 1, 0, -1, -1, -1, 0, 1]);

/// `pawnAttacks[c][sq]`: squares attacked by a pawn of colour `c` standing on `sq`.
immutable Bitboard[64][2] pawnAttacks = buildPawnAttacks();

/// `between[a][b]`: squares strictly between `a` and `b` if they share a rank, file or
/// diagonal, otherwise empty.
immutable Bitboard[64][64] between = buildBetween();

/// `line[a][b]`: the whole rank, file or diagonal through `a` and `b` (including both)
/// if they are aligned, otherwise empty.
immutable Bitboard[64][64] line = buildLine();

/// Bishop attacks on an empty board.
immutable Bitboard[64] bishopRays = buildEmptyBoard(true);
/// Rook attacks on an empty board.
immutable Bitboard[64] rookRays = buildEmptyBoard(false);

private Bitboard[64] buildEmptyBoard(bool diagonal) pure nothrow @safe
{
    Bitboard[64] t;
    foreach (sq; 0 .. 64)
        foreach (d; 0 .. 8)
            if (((d & 1) == 1) == diagonal)
                t[sq] |= rays[d][sq];
    return t;
}

// Directions that increase the square index are scanned with the lowest set
// bit, the others with the highest. OR-ing a sentinel makes the empty case
// resolve to square 63 (resp. 0), whose forward ray is empty.
pragma(inline, true)
private Bitboard positiveRay(int d)(int sq, Bitboard occ) @trusted pure nothrow @nogc
{
    Bitboard a = rays[d][sq];
    return a ^ rays[d][lsb((a & occ) | (1UL << 63))];
}

pragma(inline, true)
private Bitboard negativeRay(int d)(int sq, Bitboard occ) @trusted pure nothrow @nogc
{
    Bitboard a = rays[d][sq];
    return a ^ rays[d][msb((a & occ) | 1UL)];
}

/// Squares a bishop on `sq` attacks given the occupancy `occ` (blockers included).
pragma(inline, true)
Bitboard bishopAttacks(int sq, Bitboard occ) @trusted pure nothrow @nogc
{
    return positiveRay!(Dir.northEast)(sq, occ) | positiveRay!(Dir.northWest)(sq, occ)
        | negativeRay!(Dir.southEast)(sq, occ) | negativeRay!(Dir.southWest)(sq, occ);
}

/// Squares a rook on `sq` attacks given the occupancy `occ` (blockers included).
pragma(inline, true)
Bitboard rookAttacks(int sq, Bitboard occ) @trusted pure nothrow @nogc
{
    return positiveRay!(Dir.north)(sq, occ) | positiveRay!(Dir.east)(sq, occ)
        | negativeRay!(Dir.south)(sq, occ) | negativeRay!(Dir.west)(sq, occ);
}

/// Squares a queen on `sq` attacks given the occupancy `occ`.
pragma(inline, true)
Bitboard queenAttacks(int sq, Bitboard occ) @trusted pure nothrow @nogc
{
    return bishopAttacks(sq, occ) | rookAttacks(sq, occ);
}
