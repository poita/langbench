/++
Fully legal move generation.

No pseudo-legal move is ever generated and then tested by playing it. Instead
each node computes
$(UL
$(LI the checkers of the side to move's king,)
$(LI an evasion mask (all non-own squares if not in check; the checker plus
     the squares between it and the king if in single check),)
$(LI the set of pinned pieces, which may only move along the line through
     their king and the pinner.))
King moves are tested with the king removed from the occupancy so that
sliders see "through" it. En passant is tested explicitly on the
post-capture occupancy. Castling checks the rights, empty squares and the
attacked status of the squares the king uses.

Because every generated move is legal, counting the moves of a node gives its
perft(1) without playing anything.
+/
module chessperft.movegen;

import chessperft.bitboard;
import chessperft.move;
import chessperft.position;
import chessperft.tables;
import chessperft.types;

/// Upper bound on the number of legal moves in any chess position (the true maximum is 218).
enum size_t maxMoves = 256;

/++
Write every legal move of `pos` to `list`.
Params:
    pos = the position (not modified)
    list = destination, with room for at least `maxMoves` moves
Returns: the number of moves written.
+/
size_t generateLegal(ref const Position pos, Move* list) @trusted nothrow @nogc
{
    return pos.sideToMove == Color.white
        ? generate!(Color.white, false)(pos, list) : generate!(Color.black, false)(pos, list);
}

/// Number of legal moves in `pos`, computed without materialising them.
size_t countLegal(ref const Position pos) @trusted nothrow @nogc
{
    return pos.sideToMove == Color.white
        ? generate!(Color.white, true)(pos, null) : generate!(Color.black, true)(pos, null);
}

/// All legal moves of `pos` as a freshly allocated array.
Move[] legalMoves(ref const Position pos) @trusted nothrow
{
    auto buf = new Move[maxMoves];
    return buf[0 .. generateLegal(pos, buf.ptr)];
}

private:

// Output sink: either writes moves or merely counts them.
struct Sink(bool count_)
{
    Move* ptr;
    size_t n;

    pragma(inline, true)
    void add(int from, int to, int flag = MoveFlag.quiet) @system nothrow @nogc
    {
        static if (!count_)
            *ptr++ = Move(from, to, flag);
        n++;
    }

    // One move from `from` to every square of `targets`.
    pragma(inline, true)
    void addTargets(int from, Bitboard targets) @system nothrow @nogc
    {
        static if (count_)
            n += count(targets);
        else
            while (targets)
            {
                add(from, lsb(targets));
                targets &= targets - 1;
            }
    }

    // `targets` are pawn destinations reached by `from = to - delta`; those on `promoRank` expand to four moves.
    pragma(inline, true)
    void addPawnMoves(int delta, Bitboard targets, Bitboard promoRank, int flag = MoveFlag.quiet) @system nothrow @nogc
    {
        immutable Bitboard promo = targets & promoRank;
        Bitboard quiet = targets & ~promoRank;
        static if (count_)
            n += count(quiet) + 4 * count(promo);
        else
        {
            while (quiet)
            {
                immutable to = lsb(quiet);
                add(to - delta, to, flag);
                quiet &= quiet - 1;
            }
            Bitboard pr = promo;
            while (pr)
            {
                immutable to = lsb(pr);
                immutable from = to - delta;
                add(from, to, MoveFlag.promoteQueen);
                add(from, to, MoveFlag.promoteRook);
                add(from, to, MoveFlag.promoteBishop);
                add(from, to, MoveFlag.promoteKnight);
                pr &= pr - 1;
            }
        }
    }
}

// Pawn pushes and captures, set-wise. `mask` restricts destinations (evasions and/or pin line).
pragma(inline, true)
void generatePawnMoves(Color us, bool count_)(ref Sink!count_ sink, Bitboard pawns,
        Bitboard theirs, Bitboard empty, Bitboard mask) @system nothrow @nogc
{
    enum int push = us == Color.white ? 8 : -8;
    enum int capLeft = us == Color.white ? 7 : -9;
    enum int capRight = us == Color.white ? 9 : -7;
    enum Bitboard doubleRank = us == Color.white ? rank3 : rank6;
    enum Bitboard promoRank = us == Color.white ? rank8 : rank1;

    Bitboard single = shift!push(pawns) & empty;
    immutable Bitboard dbl = shift!push(single & doubleRank) & empty & mask;
    single &= mask;
    immutable Bitboard left = shift!capLeft(pawns & ~fileA) & theirs & mask;
    immutable Bitboard right = shift!capRight(pawns & ~fileH) & theirs & mask;

    sink.addPawnMoves(push, single, promoRank);
    sink.addPawnMoves(2 * push, dbl, 0, MoveFlag.doublePush);
    sink.addPawnMoves(capLeft, left, promoRank);
    sink.addPawnMoves(capRight, right, promoRank);
}

size_t generate(Color us, bool count_)(ref const Position pos, Move* list) @system nothrow @nogc
{
    enum Color them = opposite(us);
    auto sink = Sink!count_(list, 0);

    immutable Bitboard occ = pos.occupied;
    immutable Bitboard ours = pos.byColor[us];
    immutable Bitboard theirs = pos.byColor[them];
    immutable Bitboard pawnsAll = pos.byType[PieceType.pawn];
    immutable Bitboard knightsAll = pos.byType[PieceType.knight];
    immutable Bitboard bishopsAll = pos.byType[PieceType.bishop];
    immutable Bitboard rooksAll = pos.byType[PieceType.rook];
    immutable Bitboard queensAll = pos.byType[PieceType.queen];
    immutable int ksq = lsb(pos.byType[PieceType.king] & ours);

    // Enemy pieces giving check.
    immutable Bitboard enemyDiag = (bishopsAll | queensAll) & theirs;
    immutable Bitboard enemyOrth = (rooksAll | queensAll) & theirs;
    immutable Bitboard checkers = (pawnAttacks[us][ksq] & pawnsAll & theirs)
        | (knightAttacks[ksq] & knightsAll & theirs)
        | (bishopAttacks(ksq, occ) & enemyDiag)
        | (rookAttacks(ksq, occ) & enemyOrth);

    // King moves: the king is lifted off the board so sliders see through it.
    {
        immutable Bitboard occNoKing = occ ^ bit(ksq);
        Bitboard dests = kingAttacks[ksq] & ~ours;
        while (dests)
        {
            immutable to = lsb(dests);
            dests &= dests - 1;
            if (!pos.isAttacked(to, them, occNoKing))
                sink.add(ksq, to);
        }
    }

    if (checkers & (checkers - 1)) // double check: only the king can move
        return sink.n;

    immutable Bitboard mask = checkers ? checkers | between[ksq][lsb(checkers)] : ~ours;

    // Pinned pieces: exactly one of our pieces between the king and an enemy slider.
    Bitboard pinned = 0;
    {
        Bitboard snipers = (rookRays[ksq] & enemyOrth) | (bishopRays[ksq] & enemyDiag);
        while (snipers)
        {
            immutable Bitboard blockers = between[ksq][lsb(snipers)] & occ;
            snipers &= snipers - 1;
            if (blockers && !(blockers & (blockers - 1)))
                pinned |= blockers & ours;
        }
    }

    // Knights (a pinned knight can never move).
    {
        Bitboard b = knightsAll & ours & ~pinned;
        while (b)
        {
            immutable from = lsb(b);
            b &= b - 1;
            sink.addTargets(from, knightAttacks[from] & mask);
        }
    }

    // Sliders.
    {
        Bitboard b = (bishopsAll | queensAll) & ours;
        while (b)
        {
            immutable from = lsb(b);
            b &= b - 1;
            Bitboard t = bishopAttacks(from, occ) & mask;
            if (pinned & bit(from))
                t &= line[ksq][from];
            sink.addTargets(from, t);
        }
        b = (rooksAll | queensAll) & ours;
        while (b)
        {
            immutable from = lsb(b);
            b &= b - 1;
            Bitboard t = rookAttacks(from, occ) & mask;
            if (pinned & bit(from))
                t &= line[ksq][from];
            sink.addTargets(from, t);
        }
    }

    // Pawns: unpinned ones together, pinned ones one at a time along their pin line.
    immutable Bitboard empty = ~occ;
    immutable Bitboard ourPawns = pawnsAll & ours;
    generatePawnMoves!(us, count_)(sink, ourPawns & ~pinned, theirs, empty, mask);
    {
        Bitboard b = ourPawns & pinned;
        while (b)
        {
            immutable from = lsb(b);
            b &= b - 1;
            generatePawnMoves!(us, count_)(sink, bit(from), theirs, empty, mask & line[ksq][from]);
        }
    }

    // En passant: tested directly on the occupancy after the capture.
    if (pos.epSquare != noSquare)
    {
        immutable int ep = pos.epSquare;
        immutable int capSq = ep - (us == Color.white ? 8 : -8);
        Bitboard b = pawnAttacks[them][ep] & ourPawns;
        while (b)
        {
            immutable from = lsb(b);
            b &= b - 1;
            immutable Bitboard occAfter = (occ ^ bit(from) ^ bit(capSq)) | bit(ep);
            if (!pos.isAttacked(ksq, them, occAfter, bit(capSq)))
                sink.add(from, ep, MoveFlag.enPassant);
        }
    }

    // Castling.
    if (!checkers)
    {
        static if (us == Color.white)
        {
            enum ubyte kingside = whiteKingside, queenside = whiteQueenside;
            enum int home = e1;
        }
        else
        {
            enum ubyte kingside = blackKingside, queenside = blackQueenside;
            enum int home = e8;
        }
        if ((pos.castling & kingside) && !(occ & (bit(home + 1) | bit(home + 2)))
            && !pos.isAttacked(home + 1, them, occ) && !pos.isAttacked(home + 2, them, occ))
            sink.add(home, home + 2, MoveFlag.castle);
        if ((pos.castling & queenside) && !(occ & (bit(home - 1) | bit(home - 2) | bit(home - 3)))
            && !pos.isAttacked(home - 1, them, occ) && !pos.isAttacked(home - 2, them, occ))
            sink.add(home, home - 2, MoveFlag.castle);
    }
    return sink.n;
}
