/++
Compact move representation.

A `Move` packs the origin square, the destination square and a flag into 16
bits. Castling is encoded as the king's move; en passant as the capturing
pawn's move; promotions carry the promotion piece in the flag.
+/
module chessperft.move;

import chessperft.types;

/// Special-move flag stored in a `Move`.
enum MoveFlag : int
{
    quiet = 0, /// Ordinary move or capture.
    doublePush = 1, /// Pawn advancing two squares (sets the en passant square).
    enPassant = 2, /// En passant capture.
    castle = 3, /// Castling (king move; the rook is moved implicitly).
    promoteKnight = 4, /// Promotion to a knight.
    promoteBishop = 5, /// Promotion to a bishop.
    promoteRook = 6, /// Promotion to a rook.
    promoteQueen = 7, /// Promotion to a queen.
}

/// A chess move packed in 16 bits: `from | to << 6 | flag << 12`.
struct Move
{
    ushort bits;

    /// Build a move.
    pragma(inline, true)
    this(int from, int to, int flag = MoveFlag.quiet) @safe pure nothrow @nogc
    {
        bits = cast(ushort)(from | (to << 6) | (flag << 12));
    }

    /// Origin square.
    pragma(inline, true)
    int from() const @safe pure nothrow @nogc { return bits & 63; }

    /// Destination square.
    pragma(inline, true)
    int to() const @safe pure nothrow @nogc { return (bits >> 6) & 63; }

    /// The `MoveFlag` value.
    pragma(inline, true)
    int flag() const @safe pure nothrow @nogc { return bits >> 12; }

    /// True if this move promotes a pawn.
    pragma(inline, true)
    bool isPromotion() const @safe pure nothrow @nogc { return flag >= MoveFlag.promoteKnight; }

    /// Piece type promoted to; only meaningful if `isPromotion`.
    pragma(inline, true)
    PieceType promotionType() const @safe pure nothrow @nogc
    {
        return cast(PieceType)(flag - MoveFlag.promoteKnight + PieceType.knight);
    }

    /// UCI long algebraic notation, e.g. `e2e4`, `e1g1`, `a7a8q`.
    string toString() const @safe pure nothrow
    {
        char[5] buf = void;
        buf[0] = cast(char)('a' + (from & 7));
        buf[1] = cast(char)('1' + (from >> 3));
        buf[2] = cast(char)('a' + (to & 7));
        buf[3] = cast(char)('1' + (to >> 3));
        if (!isPromotion)
            return buf[0 .. 4].idup;
        buf[4] = "nbrq"[flag - MoveFlag.promoteKnight];
        return buf[].idup;
    }
}
