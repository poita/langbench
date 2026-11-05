/// Unit tests for FEN handling and make/unmake.
module position_test;

import std.exception : assertThrown;

import chessperft.bitboard;
import chessperft.move;
import chessperft.movegen;
import chessperft.position;
import chessperft.types;

private enum startFen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

unittest // start position
{
    auto p = Position.startPosition();
    assert(p.occupied == 0xFFFF00000000FFFFUL);
    assert(p.sideToMove == Color.white);
    assert(p.castling == allCastling);
    assert(p.epSquare == noSquare);
    assert(p.board[e1] == makePiece(Color.white, PieceType.king));
    assert(p.board[d8] == makePiece(Color.black, PieceType.queen));
    assert(p.board[28] == noPiece);
    assert(p.kingSquare(Color.black) == e8);
    assert(!p.inCheck);
    assert(p.toFen() == startFen);
}

unittest // FEN round trip, ignoring the clocks
{
    foreach (fen; [
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 b - -",
        "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w Kq e6",
        "4k3/8/8/8/8/8/8/4K2R w K -",
    ])
        assert(Position.fromFen(fen ~ " 12 34").toFen() == fen ~ " 0 1");
    // The six-field and four-field forms agree.
    assert(Position.fromFen(startFen).toFen() == Position.fromFen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -").toFen());
}

unittest // malformed FEN
{
    assertThrown!FenException(Position.fromFen(""));
    assertThrown!FenException(Position.fromFen("8/8/8/8/8/8/8/8 w - -")); // no kings
    assertThrown!FenException(Position.fromFen("4k3/8/8/8/8/8/8/4K3/8 w - -")); // 9 ranks
    assertThrown!FenException(Position.fromFen("4k3/8/8/8/8/8/8/4K2 w - -")); // short rank
    assertThrown!FenException(Position.fromFen("4k3/8/8/8/8/8/8/4K3 x - -"));
    assertThrown!FenException(Position.fromFen("4k3/8/8/8/8/8/8/4K3 w X -"));
    assertThrown!FenException(Position.fromFen("4k3/8/8/8/8/8/8/4K3 w - z9"));
    assertThrown!FenException(Position.fromFen("4k3/8/8/8/8/8/8/4K3 w - - 0 1 extra"));
    assertThrown!FenException(Position.fromFen("4k3/8/8/8/8/8/8/4Q3 w - -"));
}

unittest // check detection
{
    assert(Position.fromFen("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1").inCheck);
    assert(!Position.fromFen("4k3/8/8/8/8/8/3r4/4K3 w - - 0 1").inCheck);
    assert(Position.fromFen("4k3/8/8/8/8/6n1/8/4K3 w - - 0 1").inCheck == false);
    assert(Position.fromFen("4k3/8/8/8/8/8/3n4/4K3 w - - 0 1").inCheck == false);
    assert(Position.fromFen("4k3/8/8/8/8/3n4/8/4K3 w - - 0 1").inCheck);
}

private Move find(const Position p, string uci)
{
    foreach (m; legalMoves(p))
        if (m.toString() == uci)
            return m;
    assert(false, "move not found: " ~ uci);
}

// make followed by unmake must restore the position exactly.
private void roundTrip(string fen, string uci)
{
    auto p = Position.fromFen(fen);
    const before = p;
    auto m = find(p, uci);
    auto u = p.makeMove(m);
    assert(p != before);
    p.unmakeMove(m, u);
    assert(p == before, "unmake did not restore " ~ fen ~ " after " ~ uci);
}

unittest // make/unmake of every kind of move
{
    roundTrip(startFen, "e2e4");
    roundTrip(startFen, "g1f3");
    roundTrip("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "e1g1");
    roundTrip("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "e1c1");
    roundTrip("r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1", "e8g8");
    roundTrip("r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1", "e8c8");
    roundTrip("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "a1a8"); // rook captures rook
    roundTrip("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", "e5d6");
    roundTrip("4k3/8/8/8/3pP3/8/8/4K3 b - e3 0 1", "d4e3");
    roundTrip("4k3/P7/8/8/8/8/8/4K3 w - - 0 1", "a7a8q");
    roundTrip("1n2k3/P7/8/8/8/8/8/4K3 w - - 0 1", "a7b8n"); // capturing promotion
}

unittest // effects of moves
{
    auto p = Position.startPosition();
    auto u = p.makeMove(find(p, "e2e4"));
    assert(p.sideToMove == Color.black);
    assert(p.epSquare == 20); // e3
    assert(p.board[28] == makePiece(Color.white, PieceType.pawn));
    assert(p.board[12] == noPiece);
    p.makeMove(find(p, "g8f6"));
    assert(p.epSquare == noSquare);
}

unittest // castling moves the rook and removes the rights
{
    auto p = Position.fromFen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    p.makeMove(find(p, "e1g1"));
    assert(p.board[g1] == makePiece(Color.white, PieceType.king));
    assert(p.board[f1] == makePiece(Color.white, PieceType.rook));
    assert(p.board[h1] == noPiece);
    assert(p.castling == (blackKingside | blackQueenside));
}

unittest // rook moves and captures on corners clear rights; rights never return
{
    auto p = Position.fromFen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    p.makeMove(find(p, "a1a8")); // captures the a8 rook
    assert(p.castling == (whiteKingside | blackKingside));
    p.makeMove(find(p, "e8e7"));
    assert(p.castling == whiteKingside);

    // Promotion capture on a corner removes the right too.
    auto q = Position.fromFen("r3k2r/1P6/8/8/8/8/8/4K3 w kq - 0 1");
    q.makeMove(find(q, "b7a8q"));
    assert(q.castling == blackKingside);
}

unittest // en passant removes the captured pawn
{
    auto p = Position.fromFen("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1");
    p.makeMove(find(p, "e5d6"));
    assert(p.board[35] == noPiece); // d5 is empty again
    assert(p.board[43] == makePiece(Color.white, PieceType.pawn)); // d6
    assert(count(p.byType[PieceType.pawn]) == 1);
}

unittest // promotion replaces the pawn
{
    auto p = Position.fromFen("4k3/P7/8/8/8/8/8/4K3 w - - 0 1");
    p.makeMove(find(p, "a7a8n"));
    assert(p.board[a8] == makePiece(Color.white, PieceType.knight));
    assert(p.byType[PieceType.pawn] == 0);
}
