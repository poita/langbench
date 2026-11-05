/++
Board state: bitboards plus a mailbox, FEN parsing/printing and in-place
make/unmake of moves.
+/
module chessperft.position;

import chessperft.bitboard;
import chessperft.move;
import chessperft.tables;
import chessperft.types;

/// Thrown by FEN parsing when the text is not a valid position description.
class FenException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/++
Information needed to take back a move.

The captured piece's square is implied by the move (the destination, or the
square behind it for en passant).
+/
struct Undo
{
    Piece captured = noPiece; /// Piece removed by the move, or `noPiece`.
    ubyte castling; /// Castling rights before the move.
    ubyte epSquare; /// En passant square before the move (`noSquare` if none).
}

private immutable ubyte[64] castlingMask = buildCastlingMask();

private ubyte[64] buildCastlingMask() pure nothrow @safe
{
    ubyte[64] m;
    m[] = allCastling;
    m[a1] &= ~whiteQueenside;
    m[e1] &= ~(whiteKingside | whiteQueenside);
    m[h1] &= ~whiteKingside;
    m[a8] &= ~blackQueenside;
    m[e8] &= ~(blackKingside | blackQueenside);
    m[h8] &= ~blackKingside;
    return m;
}

/++
A chess position.

Pieces are stored once per type, once per colour and in a 64-entry mailbox.
Squares are numbered `rank * 8 + file`. Moves are applied in place with
`makeMove` and reverted with `unmakeMove`; no position copies are needed.

The halfmove clock and fullmove number are not tracked: this library has no
fifty-move, repetition or insufficient-material rules.
+/
struct Position
{
    Bitboard[6] byType; /// Pieces of each `PieceType`, both colours.
    Bitboard[2] byColor; /// Pieces of each `Color`.
    Bitboard occupied; /// All pieces.
    Piece[64] board = noPiece; /// Mailbox: the piece on each square.
    Color sideToMove = Color.white; /// Player to move.
    ubyte castling; /// Castling rights, an OR of `whiteKingside` etc.
    ubyte epSquare = noSquare; /// En passant target square, or `noSquare`.

    /// The standard starting position.
    static Position startPosition()
    {
        return fromFen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    }

    /++
    Parse a FEN record. The halfmove and fullmove fields are optional and
    ignored.
    Throws: `FenException` if the text is malformed.
    +/
    static Position fromFen(const(char)[] fen)
    {
        const(char)[][6] f;
        size_t n = 0, start = 0;
        foreach (i; 0 .. fen.length + 1)
            if (i == fen.length || fen[i] == ' ')
            {
                if (i > start)
                {
                    if (n == 6)
                        throw new FenException("too many FEN fields");
                    f[n++] = fen[start .. i];
                }
                start = i + 1;
            }
        if (n < 4)
            throw new FenException("FEN needs at least 4 fields");
        return fromFields(f[0], f[1], f[2], f[3]);
    }

    /++
    Build a position from the four meaningful FEN fields.
    Throws: `FenException` if any field is malformed.
    +/
    static Position fromFields(const(char)[] placement, const(char)[] side,
            const(char)[] castlingField, const(char)[] ep)
    {
        Position p;
        int rank = 7, file = 0;
        foreach (ch; placement)
        {
            if (ch == '/')
            {
                if (file != 8 || rank == 0)
                    throw new FenException("bad rank layout in FEN placement");
                rank--;
                file = 0;
            }
            else if (ch >= '1' && ch <= '8')
            {
                file += ch - '0';
                if (file > 8)
                    throw new FenException("rank overflows in FEN placement");
            }
            else
            {
                immutable idx = "PNBRQKpnbrqk".indexOfChar(ch);
                if (idx < 0 || file > 7)
                    throw new FenException("bad piece in FEN placement");
                p.put(rank * 8 + file, makePiece(idx < 6 ? Color.white : Color.black,
                        cast(PieceType)(idx % 6)));
                file++;
            }
        }
        if (rank != 0 || file != 8)
            throw new FenException("FEN placement must describe 8 ranks of 8 files");
        foreach (c; [Color.white, Color.black])
            if (count(p.byType[PieceType.king] & p.byColor[c]) != 1)
                throw new FenException("each side needs exactly one king");

        if (side == "w")
            p.sideToMove = Color.white;
        else if (side == "b")
            p.sideToMove = Color.black;
        else
            throw new FenException("bad side to move");

        if (castlingField != "-")
        {
            if (castlingField.length == 0)
                throw new FenException("empty castling field");
            foreach (ch; castlingField)
            {
                immutable idx = "KQkq".indexOfChar(ch);
                if (idx < 0)
                    throw new FenException("bad castling field");
                p.castling |= cast(ubyte)(1 << idx);
            }
        }

        if (ep != "-")
        {
            immutable sq = squareFromName(ep);
            if (sq < 0)
                throw new FenException("bad en passant square");
            p.epSquare = cast(ubyte) sq;
        }
        return p;
    }

    /// FEN text of the position, with halfmove clock 0 and fullmove number 1.
    string toFen() const
    {
        string s;
        foreach_reverse (rank; 0 .. 8)
        {
            int empty = 0;
            foreach (file; 0 .. 8)
            {
                immutable pc = board[rank * 8 + file];
                if (pc == noPiece)
                {
                    empty++;
                    continue;
                }
                if (empty)
                    s ~= cast(char)('0' + empty);
                empty = 0;
                s ~= "PNBRQKpnbrqk"[typeOf(pc) + 6 * colorOf(pc)];
            }
            if (empty)
                s ~= cast(char)('0' + empty);
            if (rank)
                s ~= '/';
        }
        s ~= sideToMove == Color.white ? " w " : " b ";
        if (castling == 0)
            s ~= '-';
        else
            foreach (i, ch; "KQkq")
                if (castling & (1 << i))
                    s ~= ch;
        s ~= ' ';
        s ~= epSquare == noSquare ? "-" : squareName(epSquare);
        return s ~ " 0 1";
    }

    /// Bitboard of the pieces of type `t` belonging to `c`.
    pragma(inline, true)
    Bitboard pieces(PieceType t, Color c) const @safe pure nothrow @nogc
    {
        return byType[t] & byColor[c];
    }

    /// Square of the king of colour `c`.
    pragma(inline, true)
    int kingSquare(Color c) const @safe pure nothrow @nogc
    {
        return lsb(byType[PieceType.king] & byColor[c]);
    }

    /++
    Whether `sq` is attacked by any piece of colour `by`, given the occupancy
    `occ`. Pieces in `ignore` are treated as absent attackers (the blockers
    themselves must be removed from `occ` by the caller).
    +/
    bool isAttacked(int sq, Color by, Bitboard occ, Bitboard ignore = 0) const @trusted pure nothrow @nogc
    {
        immutable Bitboard theirs = byColor[by] & ~ignore;
        if (pawnAttacks[opposite(by)][sq] & byType[PieceType.pawn] & theirs)
            return true;
        if (knightAttacks[sq] & byType[PieceType.knight] & theirs)
            return true;
        if (kingAttacks[sq] & byType[PieceType.king] & theirs)
            return true;
        immutable Bitboard diag = (byType[PieceType.bishop] | byType[PieceType.queen]) & theirs;
        if (diag && (bishopAttacks(sq, occ) & diag))
            return true;
        immutable Bitboard orth = (byType[PieceType.rook] | byType[PieceType.queen]) & theirs;
        return orth && (rookAttacks(sq, occ) & orth);
    }

    /// Whether the side to move is in check.
    bool inCheck() const @safe pure nothrow @nogc
    {
        return isAttacked(kingSquare(sideToMove), opposite(sideToMove), occupied);
    }

    /// Place `pc` on the empty square `sq`.
    pragma(inline, true)
    void put(int sq, Piece pc) @safe pure nothrow @nogc
    {
        immutable b = bit(sq);
        byType[pc & 7] |= b;
        byColor[pc >> 3] |= b;
        occupied |= b;
        board[sq] = pc;
    }

    /// Remove the piece from the occupied square `sq`.
    pragma(inline, true)
    void remove(int sq) @safe pure nothrow @nogc
    {
        immutable b = bit(sq);
        immutable pc = board[sq];
        byType[pc & 7] ^= b;
        byColor[pc >> 3] ^= b;
        occupied ^= b;
        board[sq] = noPiece;
    }

    /// Move the piece on `from` to the empty square `to`.
    pragma(inline, true)
    void relocate(int from, int to) @safe pure nothrow @nogc
    {
        immutable b = bit(from) | bit(to);
        immutable pc = board[from];
        byType[pc & 7] ^= b;
        byColor[pc >> 3] ^= b;
        occupied ^= b;
        board[from] = noPiece;
        board[to] = pc;
    }

    /++
    Play a legal (or at least pseudo-legal) move in place.
    Returns: the record needed by `unmakeMove`.
    +/
    Undo makeMove(Move m) @safe pure nothrow @nogc
    {
        immutable from = m.from, to = m.to, flag = m.flag;
        immutable us = sideToMove;
        Undo u;
        u.castling = castling;
        u.epSquare = epSquare;
        epSquare = noSquare;

        if (flag == MoveFlag.enPassant)
        {
            immutable capSq = us == Color.white ? to - 8 : to + 8;
            u.captured = board[capSq];
            remove(capSq);
        }
        else if (board[to] != noPiece)
        {
            u.captured = board[to];
            remove(to);
        }

        if (flag >= MoveFlag.promoteKnight)
        {
            remove(from);
            put(to, makePiece(us, m.promotionType));
        }
        else
        {
            relocate(from, to);
            if (flag == MoveFlag.doublePush)
                epSquare = cast(ubyte)((from + to) >> 1);
            else if (flag == MoveFlag.castle)
            {
                if (to > from)
                    relocate(to + 1, to - 1);
                else
                    relocate(to - 2, to + 1);
            }
        }

        castling &= castlingMask[from] & castlingMask[to];
        sideToMove = opposite(us);
        return u;
    }

    /// Take back `m`, which must be the last move played, given its `Undo`.
    void unmakeMove(Move m, Undo u) @safe pure nothrow @nogc
    {
        immutable from = m.from, to = m.to, flag = m.flag;
        immutable us = opposite(sideToMove);
        sideToMove = us;
        castling = u.castling;
        epSquare = u.epSquare;

        if (flag >= MoveFlag.promoteKnight)
        {
            remove(to);
            put(from, makePiece(us, PieceType.pawn));
        }
        else
        {
            relocate(to, from);
            if (flag == MoveFlag.castle)
            {
                if (to > from)
                    relocate(to - 1, to + 1);
                else
                    relocate(to + 1, to - 2);
            }
        }

        if (u.captured != noPiece)
            put(flag == MoveFlag.enPassant ? (us == Color.white ? to - 8 : to + 8) : to, u.captured);
    }
}

private int indexOfChar(string s, char c) @safe pure nothrow @nogc
{
    foreach (i, ch; s)
        if (ch == c)
            return cast(int) i;
    return -1;
}
