/**
 * Chess position: piece placement, side to move, castling rights and en
 * passant square, with FEN parsing/formatting and move application.
 *
 * The halfmove clock and fullmove number are not tracked: the problem this
 * library serves has no fifty-move or repetition rules.
 */
module chessperft.position;

import std.array : split;
import std.conv : to;
import std.exception : enforce;
import chessperft.bitboard;
import chessperft.types;

/// Thrown by `Position.fromFen` when a FEN record is malformed.
class FenException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// FEN of the standard initial position.
enum string startFen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

/**
 * A chess position. It is a small value type, so a copy is a cheap way of
 * "making" a move: `auto next = pos; next.play(m);`.
 */
struct Position
{
    /// Occupancy of each piece type (both colours), indexed by `PieceType`.
    Bitboard[6] pieces;
    /// Occupancy of each colour, indexed by `Color`.
    Bitboard[2] colors;
    /// Piece type on each square (`PieceType.none` when empty).
    PieceType[64] board = PieceType.none;
    /// Side to move.
    Color side = Color.white;
    /// Combination of `CastlingRight` flags.
    ubyte castling;
    /// En passant target square, or `noSquare`.
    Square epSquare = noSquare;

    /// All occupied squares.
    Bitboard occupied() const @safe pure nothrow @nogc
    {
        return colors[0] | colors[1];
    }

    /// Squares of the pieces of type `pt` and colour `c`.
    Bitboard pieceSet(PieceType pt, Color c) const @safe pure nothrow @nogc
    {
        return pieces[pt] & colors[c];
    }

    /// Square of the king of colour `c`. The position must contain one.
    int kingSquare(Color c) const @safe pure nothrow @nogc
    {
        return lsb(pieces[PieceType.king] & colors[c]);
    }

    /// The colour of the piece on `sq`; only meaningful on occupied squares.
    Color colorAt(int sq) const @safe pure nothrow @nogc
    {
        return (colors[Color.black] & bit(sq)) ? Color.black : Color.white;
    }

    private void put(Color c, PieceType pt, int sq) @safe pure nothrow @nogc
    {
        const b = bit(sq);
        pieces[pt] |= b;
        colors[c] |= b;
        board[sq] = pt;
    }

    private void remove(Color c, PieceType pt, int sq) @safe pure nothrow @nogc
    {
        const b = ~bit(sq);
        pieces[pt] &= b;
        colors[c] &= b;
        board[sq] = PieceType.none;
    }

    /// Whether `sq` is attacked by any piece of colour `by`, given occupancy `occ`.
    bool isAttacked(int sq, Color by, Bitboard occ) const @safe pure nothrow @nogc
    {
        const theirs = colors[by];
        if (pawnAttacks(opposite(by), sq) & pieces[PieceType.pawn] & theirs)
            return true;
        if (knightAttacks(sq) & pieces[PieceType.knight] & theirs)
            return true;
        if (kingAttacks(sq) & pieces[PieceType.king] & theirs)
            return true;
        const diag = (pieces[PieceType.bishop] | pieces[PieceType.queen]) & theirs;
        if (diag && (bishopAttacks(sq, occ) & diag))
            return true;
        const orth = (pieces[PieceType.rook] | pieces[PieceType.queen]) & theirs;
        return orth && (rookAttacks(sq, occ) & orth);
    }

    /// All pieces of either colour attacking `sq` given occupancy `occ`.
    Bitboard attackersTo(int sq, Bitboard occ) const @safe pure nothrow @nogc
    {
        return (pawnAttacks(Color.black, sq) & pieces[PieceType.pawn] & colors[Color.white])
            | (pawnAttacks(Color.white, sq) & pieces[PieceType.pawn] & colors[Color.black])
            | (knightAttacks(sq) & pieces[PieceType.knight])
            | (kingAttacks(sq) & pieces[PieceType.king])
            | (bishopAttacks(sq, occ) & (pieces[PieceType.bishop] | pieces[PieceType.queen]))
            | (rookAttacks(sq, occ) & (pieces[PieceType.rook] | pieces[PieceType.queen]));
    }

    /// Whether the side to move is in check.
    bool inCheck() const @safe pure nothrow @nogc
    {
        return isAttacked(kingSquare(side), opposite(side), occupied);
    }

    /**
     * Plays `m` (assumed pseudo-legal for the side to move) in place: moves
     * pieces, handles captures, en passant, castling and promotion, updates
     * castling rights and the en passant square, and passes the turn.
     */
    void play(Move m) @safe pure nothrow @nogc
    {
        const us = side, them = opposite(us);
        const mover = board[m.from];
        const captured = board[m.to];

        if (captured != PieceType.none)
            remove(them, captured, m.to);
        else if (mover == PieceType.pawn && m.to == epSquare && fileOf(m.from) != fileOf(m.to))
            remove(them, PieceType.pawn, us == Color.white ? m.to - 8 : m.to + 8);

        remove(us, mover, m.from);
        put(us, m.promotion != PieceType.none ? m.promotion : mover, m.to);

        if (mover == PieceType.king && (m.to - m.from == 2 || m.from - m.to == 2))
        {
            const kingside = m.to > m.from;
            const rookFrom = kingside ? m.to + 1 : m.to - 2;
            const rookTo = kingside ? m.to - 1 : m.to + 1;
            remove(us, PieceType.rook, rookFrom);
            put(us, PieceType.rook, rookTo);
        }

        castling &= castlingMask[m.from] & castlingMask[m.to];
        epSquare = noSquare;
        if (mover == PieceType.pawn && (m.to - m.from == 16 || m.from - m.to == 16))
            epSquare = cast(Square)((m.from + m.to) / 2);
        side = them;
    }

    /**
     * Parses a FEN record. The halfmove and fullmove fields are optional and
     * ignored.
     * Throws: `FenException` if the record is malformed.
     */
    static Position fromFen(const(char)[] fen) @safe
    {
        const fields = fen.idup.split(' ');
        if (fields.length < 4)
            throw new FenException("FEN needs at least 4 fields: " ~ fen.idup);
        Position pos;

        const ranks = fields[0].split('/');
        if (ranks.length != 8)
            throw new FenException("FEN placement needs 8 ranks: " ~ fen.idup);
        foreach (i, rankStr; ranks)
        {
            const rank = 7 - cast(int) i;
            int file = 0;
            foreach (ch; rankStr)
            {
                if (ch >= '1' && ch <= '8')
                {
                    file += ch - '0';
                    continue;
                }
                if (file > 7)
                    throw new FenException("rank too long: " ~ rankStr);
                const c = (ch >= 'a' && ch <= 'z') ? Color.black : Color.white;
                const pt = pieceFromChar(ch);
                if (pt == PieceType.none)
                    throw new FenException("invalid piece: " ~ ch.to!string);
                pos.put(c, pt, makeSquare(file, rank));
                file++;
            }
            if (file != 8)
                throw new FenException("rank does not have 8 squares: " ~ rankStr);
        }

        if (fields[1] == "w")
            pos.side = Color.white;
        else if (fields[1] == "b")
            pos.side = Color.black;
        else
            throw new FenException("invalid side to move: " ~ fields[1]);

        if (fields[2] != "-")
            foreach (ch; fields[2])
            {
                switch (ch)
                {
                case 'K': pos.castling |= CastlingRight.whiteKingside; break;
                case 'Q': pos.castling |= CastlingRight.whiteQueenside; break;
                case 'k': pos.castling |= CastlingRight.blackKingside; break;
                case 'q': pos.castling |= CastlingRight.blackQueenside; break;
                default: throw new FenException("invalid castling field: " ~ fields[2]);
                }
            }

        if (fields[3] != "-")
        {
            try
                pos.epSquare = parseSquare(fields[3]);
            catch (Exception e)
                throw new FenException("invalid en passant square: " ~ fields[3]);
        }

        foreach (c; [Color.white, Color.black])
            if (popCount(pos.pieceSet(PieceType.king, c)) != 1)
                throw new FenException("each side needs exactly one king");
        return pos;
    }

    /// Formats the position as FEN, with halfmove clock 0 and fullmove number 1.
    string toFen() const @safe
    {
        string s;
        foreach_reverse (rank; 0 .. 8)
        {
            int empty = 0;
            foreach (file; 0 .. 8)
            {
                const sq = makeSquare(file, rank);
                if (board[sq] == PieceType.none)
                {
                    empty++;
                    continue;
                }
                if (empty)
                {
                    s ~= cast(char)('0' + empty);
                    empty = 0;
                }
                s ~= pieceChar(board[sq], colorAt(sq));
            }
            if (empty)
                s ~= cast(char)('0' + empty);
            if (rank)
                s ~= '/';
        }
        s ~= side == Color.white ? " w " : " b ";
        if (castling == 0)
            s ~= '-';
        else
        {
            if (castling & CastlingRight.whiteKingside) s ~= 'K';
            if (castling & CastlingRight.whiteQueenside) s ~= 'Q';
            if (castling & CastlingRight.blackKingside) s ~= 'k';
            if (castling & CastlingRight.blackQueenside) s ~= 'q';
        }
        s ~= ' ';
        s ~= epSquare == noSquare ? "-" : squareName(epSquare);
        return s ~ " 0 1";
    }
}

/// Castling rights that survive a move touching each square (as origin or destination).
private immutable ubyte[64] castlingMask = () {
    ubyte[64] m;
    m[] = CastlingRight.all;
    m[makeSquare(4, 0)] &= ~(CastlingRight.whiteKingside | CastlingRight.whiteQueenside);
    m[makeSquare(0, 0)] &= ~CastlingRight.whiteQueenside;
    m[makeSquare(7, 0)] &= ~CastlingRight.whiteKingside;
    m[makeSquare(4, 7)] &= ~(CastlingRight.blackKingside | CastlingRight.blackQueenside);
    m[makeSquare(0, 7)] &= ~CastlingRight.blackQueenside;
    m[makeSquare(7, 7)] &= ~CastlingRight.blackKingside;
    return m;
}();

private PieceType pieceFromChar(char ch) @safe pure nothrow @nogc
{
    switch (ch)
    {
    case 'P': case 'p': return PieceType.pawn;
    case 'N': case 'n': return PieceType.knight;
    case 'B': case 'b': return PieceType.bishop;
    case 'R': case 'r': return PieceType.rook;
    case 'Q': case 'q': return PieceType.queen;
    case 'K': case 'k': return PieceType.king;
    default: return PieceType.none;
    }
}

private char pieceChar(PieceType pt, Color c) @safe pure nothrow @nogc
{
    static immutable string white = "PNBRQK";
    static immutable string black = "pnbrqk";
    return c == Color.white ? white[pt] : black[pt];
}

@safe unittest
{
    import std.exception : assertThrown;

    const p = Position.fromFen(startFen);
    assert(p.toFen == startFen);
    assert(p.side == Color.white);
    assert(p.castling == CastlingRight.all);
    assert(p.epSquare == noSquare);
    assert(popCount(p.occupied) == 32);
    assert(p.kingSquare(Color.white) == parseSquare("e1"));
    assert(p.kingSquare(Color.black) == parseSquare("e8"));
    assert(!p.inCheck);

    // Halfmove/fullmove are optional on input.
    assert(Position.fromFen("8/8/8/8/8/8/8/K6k b - -").side == Color.black);

    assertThrown!FenException(Position.fromFen("8/8/8/8/8/8/8 w - -"));
    assertThrown!FenException(Position.fromFen("8/8/8/8/8/8/8/K7 w - -"));
    assertThrown!FenException(Position.fromFen("8/8/8/8/8/8/8/K6k x - -"));
    assertThrown!FenException(Position.fromFen("8/8/8/8/8/8/8/K6k w X -"));
    assertThrown!FenException(Position.fromFen("8/8/8/8/8/8/8/K6k w - z9"));
    assertThrown!FenException(Position.fromFen("8/8/8/8/8/8/8/K6x w - -"));
    assertThrown!FenException(Position.fromFen("8/8/8/8/8/8/8/K6k"));
}

@safe unittest
{
    // Double push sets the en passant square; the next move clears it.
    auto p = Position.fromFen(startFen);
    p.play(Move.fromUci("e2e4"));
    assert(p.toFen == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1");
    p.play(Move.fromUci("g8f6"));
    assert(p.epSquare == noSquare);
    assert(p.side == Color.white);
}

@safe unittest
{
    // En passant removes the captured pawn.
    auto p = Position.fromFen("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1");
    p.play(Move.fromUci("e5d6"));
    assert(p.toFen == "4k3/8/3P4/8/8/8/8/4K3 b - - 0 1");
}

@safe unittest
{
    // Castling moves the rook and removes rights; rook capture removes a right.
    auto p = Position.fromFen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    auto q = p;
    q.play(Move.fromUci("e1g1"));
    assert(q.toFen == "r3k2r/8/8/8/8/8/8/R4RK1 b kq - 0 1");
    q = p;
    q.play(Move.fromUci("e1c1"));
    assert(q.toFen == "r3k2r/8/8/8/8/8/8/2KR3R b kq - 0 1");
    q = p;
    q.play(Move.fromUci("a1a8"));
    assert(q.toFen == "R3k2r/8/8/8/8/8/8/4K2R b Kk - 0 1");
    q = p;
    q.play(Move.fromUci("h1h8"));
    assert(q.castling == (CastlingRight.whiteQueenside | CastlingRight.blackQueenside));
}

@safe unittest
{
    // Promotion, including with capture on a corner square.
    auto p = Position.fromFen("r3k3/1P6/8/8/8/8/8/4K3 w q - 0 1");
    p.play(Move.fromUci("b7a8q"));
    assert(p.toFen == "Q3k3/8/8/8/8/8/8/4K3 b - - 0 1");
}

@safe unittest
{
    // Attack queries; sliders see through a vacated square.
    const p = Position.fromFen("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1");
    assert(p.inCheck);
    assert(p.isAttacked(parseSquare("e1"), Color.black, p.occupied));
    assert(!p.isAttacked(parseSquare("a1"), Color.black, p.occupied));
    assert(popCount(p.attackersTo(parseSquare("e1"), p.occupied)) == 1);
}
