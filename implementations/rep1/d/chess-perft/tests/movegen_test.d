/// Unit tests for legal move generation on tricky positions.
module movegen_test;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : array;
import std.algorithm.iteration : map;

import chessperft.movegen;
import chessperft.position;

private string[] uciMoves(string fen)
{
    auto p = Position.fromFen(fen);
    auto s = legalMoves(p).map!(m => m.toString()).array;
    s.sort();
    return s;
}

unittest // start position
{
    auto p = Position.startPosition();
    assert(legalMoves(p).length == 20);
    assert(countLegal(p) == 20);
}

unittest // count agrees with generation
{
    foreach (fen; [
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    ])
    {
        auto p = Position.fromFen(fen);
        assert(countLegal(p) == legalMoves(p).length);
    }
}

unittest // promotions produce four moves each
{
    assert(uciMoves("8/P1k5/K7/8/8/8/8/8 w - - 0 1")
        == ["a6a5", "a6b5", "a7a8b", "a7a8n", "a7a8q", "a7a8r"]);
}

unittest // no moves: stalemate and checkmate
{
    assert(uciMoves("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").length == 0);
    assert(uciMoves("7k/6Q1/6K1/8/8/8/8/8 b - - 0 1").length == 0);
}

unittest // king may not step back along a checking slider's line
{
    // Rook on e8 checks the king on e4: e3 is attacked through the king, d4/f4 are fine.
    auto m = uciMoves("4r2k/8/8/8/4K3/8/8/8 w - - 0 1");
    assert(!m.canFind("e4e3") && !m.canFind("e4e5"));
    assert(m.canFind("e4d4") && m.canFind("e4f4"));
}

unittest // double check allows only king moves
{
    // Knight on f6... checks e4 along with the rook on e8.
    auto m = uciMoves("4r2k/8/5n2/8/4K3/8/3Q4/8 w - - 0 1");
    foreach (s; m)
        assert(s[0 .. 2] == "e4", "non-king move in double check: " ~ s);
    assert(m.length > 0);
}

unittest // pinned pieces move only along the pin
{
    // The e2 bishop is pinned on the e-file by the rook on e8: no moves.
    auto m = uciMoves("4r2k/8/8/8/8/8/4B3/4K3 w - - 0 1");
    foreach (s; m)
        assert(s[0 .. 2] == "e1");
    // The e2 rook is pinned on the file: it may slide along it, even capture the pinner.
    auto r = uciMoves("4r2k/8/8/8/8/8/4R3/4K3 w - - 0 1");
    assert(r.canFind("e2e8") && r.canFind("e2e3") && !r.canFind("e2d2"));
    // A pinned knight never moves.
    foreach (s; uciMoves("4r2k/8/8/8/8/8/4N3/4K3 w - - 0 1"))
        assert(s[0 .. 2] == "e1");
}

unittest // pinned pawns
{
    // Pawn on e2 pinned on the e-file may still advance.
    auto m = uciMoves("4r2k/8/8/8/8/8/4P3/4K3 w - - 0 1");
    assert(m.canFind("e2e3") && m.canFind("e2e4"));
    // Pawn on d2 pinned diagonally by a bishop on a5 cannot push.
    auto n = uciMoves("7k/8/8/b7/8/8/3P4/4K3 w - - 0 1");
    assert(!n.canFind("d2d3") && !n.canFind("d2d4"));
    // Pinned on a diagonal it can capture the pinner.
    auto c = uciMoves("7k/8/8/8/8/2b5/3P4/4K3 w - - 0 1");
    assert(c.canFind("d2c3"));
}

unittest // castling rules
{
    enum base = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1";
    auto m = uciMoves(base);
    assert(m.canFind("e1g1") && m.canFind("e1c1"));
    // Right missing.
    assert(!uciMoves("r3k2r/8/8/8/8/8/8/R3K2R w Qkq - 0 1").canFind("e1g1"));
    // Blocked path.
    assert(!uciMoves("r3k2r/8/8/8/8/8/8/RN2K2R w KQkq - 0 1").canFind("e1c1"));
    // b1 may be attacked, the rook may be attacked.
    assert(uciMoves("1r2k3/8/8/8/8/8/8/R3K3 w Q - 0 1").canFind("e1c1"));
    // Transit square attacked.
    assert(!uciMoves("4kr2/8/8/8/8/8/8/4K2R w K - 0 1").canFind("e1g1"));
    // Landing square attacked.
    assert(!uciMoves("4k1r1/8/8/8/8/8/8/4K2R w K - 0 1").canFind("e1g1"));
    // In check.
    assert(!uciMoves("4k3/8/8/8/8/8/4r3/R3K2R w KQ - 0 1").canFind("e1g1"));
    // Black castles too.
    assert(uciMoves("r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1").canFind("e8c8"));
}

unittest // en passant
{
    assert(uciMoves("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1").canFind("e5d6"));
    // The ep square given but no capturing pawn: no extra move.
    assert(uciMoves("4k3/8/8/3p4/8/8/8/4K3 w - d6 0 1").length == 5);
    // Pawn that just advanced gives check and can be captured en passant.
    assert(uciMoves("8/8/8/2k5/3Pp3/8/8/4K3 b - d3 0 1").canFind("e4d3"));
    // Horizontal pin along the rank vacated by both pawns makes the capture illegal.
    assert(!uciMoves("8/8/8/KPp4r/8/8/8/7k w - c6 0 1").canFind("b5c6"));
    // ... but it is legal if the king is not on that rank.
    assert(uciMoves("8/8/8/1Pp4r/8/8/8/K6k w - c6 0 1").canFind("b5c6"));
}

unittest // en passant and diagonal pins
{
    // Pawn e5 is pinned by the bishop on b8 against the king on h2.
    // Capturing towards f6 leaves the pin line: illegal.
    assert(!uciMoves("1b2k3/8/8/4Pp2/8/8/7K/8 w - f6 0 1").canFind("e5f6"));
    // Capturing towards d6 stays on the pin line (and blocks it): legal.
    assert(uciMoves("1b2k3/8/8/3pP3/8/8/7K/8 w - d6 0 1").canFind("e5d6"));
}
