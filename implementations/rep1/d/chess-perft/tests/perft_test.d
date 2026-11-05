/// Unit tests for perft, divide and the query protocol, against published values.
module perft_test;

import chessperft.perft;
import chessperft.position;
import chessperft.query;

private enum startFen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
private enum kiwipete = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
private enum pos3 = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
private enum pos4 = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1";
private enum pos5 = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8";
private enum pos6 = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10";

private void check(string fen, ulong[] expected)
{
    auto p = Position.fromFen(fen);
    const before = p;
    foreach (i, n; expected)
        assert(perft(p, cast(int) i + 1) == n, fen);
    assert(p == before, "perft must leave the position unchanged");
}

unittest // reference values
{
    check(startFen, [20, 400, 8902, 197_281, 4_865_609]);
    check(kiwipete, [48, 2039, 97_862, 4_085_603]);
    check(pos3, [14, 191, 2812, 43_238, 674_624]);
    check(pos4, [6, 264, 9467, 422_333]);
    check(pos5, [44, 1486, 62_379, 2_103_487]);
    check(pos6, [46, 2079, 89_890]);
}

unittest // depth zero and mate/stalemate
{
    auto p = Position.startPosition();
    assert(perft(p, 0) == 1);
    auto stalemate = Position.fromFen("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1");
    assert(perft(stalemate, 0) == 1);
    assert(perft(stalemate, 1) == 0);
    assert(perft(stalemate, 3) == 0);
}

unittest // divide sums to perft and is sorted
{
    auto p = Position.fromFen(kiwipete);
    auto r = divide(p, 3);
    assert(r.entries.length == 48);
    assert(r.total == 97_862);
    ulong sum = 0;
    foreach (i, e; r.entries)
    {
        sum += e.count;
        if (i)
            assert(r.entries[i - 1].move < e.move);
    }
    assert(sum == r.total);
}

unittest // divide at depth 1 and with no moves
{
    auto p = Position.startPosition();
    auto r = divide(p, 1);
    assert(r.total == 20);
    foreach (e; r.entries)
        assert(e.count == 1);
    auto s = Position.fromFen("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1");
    auto none = divide(s, 3);
    assert(none.entries.length == 0 && none.total == 0);
}

unittest // query protocol
{
    assert(answerAll(startFen ~ " 1\n" ~ startFen ~ " 3\n") == "20\n8902\n");
    assert(answerAll(startFen ~ " 2") == "400\n"); // no trailing newline
    assert(answerAll("") == "");
    assert(answerAll("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1 0\n") == "1\n");
    assert(answerAll("8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1\n")
        == "a6a5 1\na6b5 1\na7a8b 1\na7a8n 1\na7a8q 1\na7a8r 1\ntotal 6\n");
    assert(answerAll("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3\n") == "total 0\n");
}

unittest // query parsing errors
{
    import std.exception : assertThrown;

    assertThrown!FenException(parseQuery("nonsense"));
    assertThrown!FenException(parseQuery(startFen ~ " divide 0"));
    auto q = parseQuery(startFen ~ " divide 2");
    assert(q.isDivide && q.depth == 2);
}
