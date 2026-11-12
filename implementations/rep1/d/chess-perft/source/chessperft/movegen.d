/**
 * Legal move generation.
 *
 * The generator computes the checkers of the side to move's king and the
 * pieces pinned to it, and uses them to emit only legal moves: ordinary
 * moves are masked by the check-resolution squares and the pin line, king
 * moves are checked against the enemy attacks (with the king lifted off the
 * board), and only en passant captures are verified by playing them.
 *
 * Generation is written against a "sink" so the same code either stores
 * moves (`MoveList`) or merely counts them (`MoveCounter`); the latter is
 * what makes bulk counting at the perft leaves cheap.
 */
module chessperft.movegen;

import chessperft.bitboard;
import chessperft.position;
import chessperft.types;

/// Upper bound on the number of legal moves in any chess position is 218.
enum size_t maxMoves = 256;

/// A fixed-capacity list of moves living on the stack.
struct MoveList
{
    private Move[maxMoves] moves;
    private size_t length_;

    /// Number of moves stored.
    size_t length() const @safe pure nothrow @nogc
    {
        return length_;
    }

    /// The stored moves as a slice (valid while the list is alive and unchanged).
    inout(Move)[] opSlice() inout @safe pure nothrow @nogc return
    {
        return moves[0 .. length_];
    }

    /// Indexing.
    Move opIndex(size_t i) const @safe pure nothrow @nogc
    {
        return moves[i];
    }

    // Sink interface used by `generate`.

    package void addTargets(int from, Bitboard targets) @safe pure nothrow @nogc
    {
        while (targets)
            moves[length_++] = Move(cast(Square) from, cast(Square) popLsb(targets));
    }

    package void addPawnMove(int from, int to) @safe pure nothrow @nogc
    {
        const r = rankOf(to);
        if (r == 0 || r == 7)
            foreach (pt; [PieceType.queen, PieceType.rook, PieceType.bishop, PieceType.knight])
                moves[length_++] = Move(cast(Square) from, cast(Square) to, pt);
        else
            moves[length_++] = Move(cast(Square) from, cast(Square) to);
    }

    package void addMove(int from, int to) @safe pure nothrow @nogc
    {
        moves[length_++] = Move(cast(Square) from, cast(Square) to);
    }
}

/// A move sink that only counts.
struct MoveCounter
{
    /// Number of moves seen so far.
    size_t count;

    package void addTargets(int, Bitboard targets) @safe pure nothrow @nogc
    {
        count += popCount(targets);
    }

    package void addPawnMove(int, int to) @safe pure nothrow @nogc
    {
        const r = rankOf(to);
        count += (r == 0 || r == 7) ? 4 : 1;
    }

    package void addMove(int, int) @safe pure nothrow @nogc
    {
        count++;
    }
}

/// Returns all legal moves of the side to move.
MoveList legalMoves(const ref Position pos) @safe pure nothrow @nogc
{
    MoveList list;
    generate(pos, list);
    return list;
}

/// Counts the legal moves of the side to move without materialising them.
size_t countLegalMoves(const ref Position pos) @safe pure nothrow @nogc
{
    MoveCounter counter;
    generate(pos, counter);
    return counter.count;
}

/**
 * Generates every legal move of the side to move into `sink`.
 *
 * `Sink` must provide `addTargets(int from, Bitboard to)`,
 * `addPawnMove(int from, int to)` (expands promotions) and
 * `addMove(int from, int to)`.
 */
package void generate(Sink)(const ref Position pos, ref Sink sink) @safe pure nothrow @nogc
{
    const us = pos.side, them = opposite(us);
    const occ = pos.occupied;
    const ours = pos.colors[us], theirs = pos.colors[them];
    const ksq = pos.kingSquare(us);

    // King moves: destination must not be attacked once the king has left its square.
    {
        Bitboard dests = 0;
        Bitboard cand = kingAttacks(ksq) & ~ours;
        const occNoKing = occ ^ bit(ksq);
        while (cand)
        {
            const to = popLsb(cand);
            if (!pos.isAttacked(to, them, occNoKing))
                dests |= bit(to);
        }
        sink.addTargets(ksq, dests);
    }

    const checkers = pos.attackersTo(ksq, occ) & theirs;
    const numCheckers = popCount(checkers);
    if (numCheckers > 1)
        return; // double check: king moves only

    // Squares a non-king move may land on: anywhere, or capture/block the single checker.
    Bitboard checkMask = ~0UL;
    if (numCheckers == 1)
        checkMask = between(ksq, lsb(checkers)) | checkers;

    // Pieces pinned against the king by enemy sliders.
    Bitboard pinned = 0;
    {
        Bitboard snipers = ((pos.pieces[PieceType.rook] | pos.pieces[PieceType.queen]) & rookRays(ksq))
            | ((pos.pieces[PieceType.bishop] | pos.pieces[PieceType.queen]) & bishopRays(ksq));
        snipers &= theirs;
        while (snipers)
        {
            const blockers = between(ksq, popLsb(snipers)) & occ;
            if (blockers && !(blockers & (blockers - 1)) && (blockers & ours))
                pinned |= blockers;
        }
    }

    // Knights, bishops, rooks and queens.
    static foreach (pt; [PieceType.knight, PieceType.bishop, PieceType.rook, PieceType.queen])
    {{
        Bitboard set = pos.pieces[pt] & ours;
        while (set)
        {
            const from = popLsb(set);
            static if (pt == PieceType.knight)
                Bitboard att = knightAttacks(from);
            else static if (pt == PieceType.bishop)
                Bitboard att = bishopAttacks(from, occ);
            else static if (pt == PieceType.rook)
                Bitboard att = rookAttacks(from, occ);
            else
                Bitboard att = queenAttacks(from, occ);
            att &= ~ours & checkMask;
            if (pinned & bit(from))
                att &= line(ksq, from);
            sink.addTargets(from, att);
        }
    }}

    // Pawns.
    {
        const forward = us == Color.white ? 8 : -8;
        const startRank = us == Color.white ? 1 : 6;
        Bitboard set = pos.pieces[PieceType.pawn] & ours;
        while (set)
        {
            const from = popLsb(set);
            const allowed = checkMask & ((pinned & bit(from)) ? line(ksq, from) : ~0UL);
            const one = from + forward;
            if (!(occ & bit(one)))
            {
                if (bit(one) & allowed)
                    sink.addPawnMove(from, one);
                const two = one + forward;
                if (rankOf(from) == startRank && !(occ & bit(two)) && (bit(two) & allowed))
                    sink.addMove(from, two);
            }
            Bitboard caps = pawnAttacks(us, from) & theirs & allowed;
            while (caps)
                sink.addPawnMove(from, popLsb(caps));

            // En passant: verified by playing the capture (rare, and the
            // discovered rank attack makes mask logic error-prone).
            if (pos.epSquare != noSquare && (pawnAttacks(us, from) & bit(pos.epSquare)))
            {
                Position next = pos;
                next.play(Move(cast(Square) from, pos.epSquare));
                if (!next.isAttacked(ksq, them, next.occupied))
                    sink.addMove(from, pos.epSquare);
            }
        }
    }

    // Castling.
    if (numCheckers == 0)
    {
        const rank = us == Color.white ? 0 : 7;
        if (ksq == makeSquare(4, rank))
        {
            const kingsideRight = us == Color.white ? CastlingRight.whiteKingside : CastlingRight.blackKingside;
            const queensideRight = us == Color.white ? CastlingRight.whiteQueenside : CastlingRight.blackQueenside;
            if ((pos.castling & kingsideRight)
                && !(occ & (bit(makeSquare(5, rank)) | bit(makeSquare(6, rank))))
                && !pos.isAttacked(makeSquare(5, rank), them, occ)
                && !pos.isAttacked(makeSquare(6, rank), them, occ))
                sink.addMove(ksq, makeSquare(6, rank));
            if ((pos.castling & queensideRight)
                && !(occ & (bit(makeSquare(1, rank)) | bit(makeSquare(2, rank)) | bit(makeSquare(3, rank))))
                && !pos.isAttacked(makeSquare(3, rank), them, occ)
                && !pos.isAttacked(makeSquare(2, rank), them, occ))
                sink.addMove(ksq, makeSquare(2, rank));
        }
    }
}

version (unittest)
{
    private string[] uciMoves(string fen)
    {
        import std.algorithm : map, sort;
        import std.array : array;

        const pos = Position.fromFen(fen);
        const list = legalMoves(pos);
        auto r = list[].map!(m => m.toString).array;
        sort(r);
        assert(countLegalMoves(pos) == r.length);
        return r;
    }
}

unittest
{
    assert(uciMoves(startFen).length == 20);
    // Pawn with four promotions; king restricted by the enemy king.
    assert(uciMoves("8/P1k5/K7/8/8/8/8/8 w - - 0 1")
        == ["a6a5", "a6b5", "a7a8b", "a7a8n", "a7a8q", "a7a8r"]);
}

unittest
{
    // Stalemate and checkmate have no moves.
    assert(uciMoves("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").length == 0);
    assert(uciMoves("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3").length == 0);
}

unittest
{
    import std.algorithm : canFind;

    // Castling both sides available.
    auto m = uciMoves("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    assert(m.canFind("e1g1") && m.canFind("e1c1"));
    // Not through an attacked square (f1 attacked by rook on f8).
    m = uciMoves("4kr2/8/8/8/8/8/8/R3K2R w KQ - 0 1");
    assert(!m.canFind("e1g1") && m.canFind("e1c1"));
    // b1 may be attacked for queenside castling.
    m = uciMoves("1r2k3/8/8/8/8/8/8/R3K3 w Q - 0 1");
    assert(m.canFind("e1c1"));
    // Not while in check.
    m = uciMoves("4k3/8/8/8/8/8/4r3/R3K2R w KQ - 0 1");
    assert(!m.canFind("e1g1") && !m.canFind("e1c1"));
    // Not with a piece in the way.
    m = uciMoves("4k3/8/8/8/8/8/8/RN2K2R w KQ - 0 1");
    assert(!m.canFind("e1c1") && m.canFind("e1g1"));
    // No right, no castling.
    m = uciMoves("r3k2r/8/8/8/8/8/8/R3K2R b Kq - 0 1");
    assert(!m.canFind("e8g8") && m.canFind("e8c8"));
}

unittest
{
    import std.algorithm : canFind;

    // En passant is legal...
    auto m = uciMoves("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1");
    assert(m.canFind("e5d6"));
    // ...unless it exposes the king along the rank.
    m = uciMoves("8/8/8/KPp4r/8/8/8/7k w - c6 0 1");
    assert(!m.canFind("b5c6"));
    // ...or the pawn is pinned diagonally and leaves the pin line.
    m = uciMoves("4k3/5b2/8/2pP4/8/8/K7/8 w - c6 0 1");
    assert(!m.canFind("d5c6") && !m.canFind("d5d6"));
    // Capturing en passant along the pin line is fine.
    m = uciMoves("4k3/5b2/8/3Pp3/8/8/K7/8 w - e6 0 1");
    assert(m.canFind("d5e6") && !m.canFind("d5d6"));
    // En passant that removes the checking pawn.
    m = uciMoves("8/8/8/2k5/3Pp3/8/8/4K3 b - d3 0 1");
    assert(m.canFind("e4d3"));
    // En passant square that no pawn can use yields no move.
    m = uciMoves("4k3/8/8/8/4P3/8/8/4K3 b - e3 0 1");
    assert(m == uciMoves("4k3/8/8/8/4P3/8/8/4K3 b - - 0 1"));
}

unittest
{
    import std.algorithm : canFind;

    // Pinned pieces move only along the pin line.
    auto m = uciMoves("4k3/4r3/8/8/8/8/4R3/4K3 w - - 0 1");
    assert(m.canFind("e2e7") && m.canFind("e2e3") && !m.canFind("e2d2"));
    // A pinned knight cannot move at all.
    m = uciMoves("4k3/4r3/8/8/8/8/4N3/4K3 w - - 0 1");
    foreach (x; m)
        assert(x[0 .. 2] != "e2");
    // Single check: only capture or block.
    m = uciMoves("4k3/8/8/8/8/8/4r3/R3K3 w - - 0 1");
    assert(m.canFind("e1e2") && !m.canFind("a1a2") && !m.canFind("e1d2"));
    // Block a slider check from afar.
    m = uciMoves("4k3/4r3/8/8/8/3B4/8/4K3 w - - 0 1");
    assert(m.canFind("d3e4") && !m.canFind("d3c4"));
    // King cannot retreat along the checking ray.
    m = uciMoves("4k3/8/8/8/8/8/8/r3K3 w - - 0 1");
    assert(!m.canFind("e1d1") && !m.canFind("e1f1"));
}
