/++
Bitboard primitives: a 64-bit set of squares and a few bit-twiddling helpers.

Squares are numbered `rank * 8 + file`, so a1 = 0, h1 = 7, a8 = 56, h8 = 63.
+/
module chessperft.bitboard;

import core.bitop : bsf, bsr, popcnt;

/// A set of squares; bit `n` is set when square `n` is a member.
alias Bitboard = ulong;

/// Sentinel square index meaning "no square" (e.g. no en passant target).
enum int noSquare = 64;

enum Bitboard fileA = 0x0101010101010101UL; /// All squares of the a-file.
enum Bitboard fileH = 0x8080808080808080UL; /// All squares of the h-file.
enum Bitboard rank1 = 0x00000000000000FFUL; /// All squares of rank 1.
enum Bitboard rank3 = 0x0000000000FF0000UL; /// All squares of rank 3.
enum Bitboard rank6 = 0x0000FF0000000000UL; /// All squares of rank 6.
enum Bitboard rank8 = 0xFF00000000000000UL; /// All squares of rank 8.

/// The singleton set containing `sq`.
pragma(inline, true)
Bitboard bit(int sq) @safe pure nothrow @nogc
{
    return 1UL << sq;
}

/// Index of the least significant set bit. `b` must be non-zero.
pragma(inline, true)
int lsb(Bitboard b) @safe pure nothrow @nogc
{
    return bsf(b);
}

/// Index of the most significant set bit. `b` must be non-zero.
pragma(inline, true)
int msb(Bitboard b) @safe pure nothrow @nogc
{
    return bsr(b);
}

/// Number of squares in the set.
pragma(inline, true)
int count(Bitboard b) @safe pure nothrow @nogc
{
    return popcnt(b);
}

/// File (0 = a .. 7 = h) of a square.
pragma(inline, true)
int fileOf(int sq) @safe pure nothrow @nogc
{
    return sq & 7;
}

/// Rank (0 = rank 1 .. 7 = rank 8) of a square.
pragma(inline, true)
int rankOf(int sq) @safe pure nothrow @nogc
{
    return sq >> 3;
}

/// Shift a bitboard by a signed number of squares (positive = towards higher indices).
pragma(inline, true)
Bitboard shift(int delta)(Bitboard b) @safe pure nothrow @nogc
{
    static if (delta >= 0)
        return b << delta;
    else
        return b >> -delta;
}
