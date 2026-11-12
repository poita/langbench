/**
 * Perft: counting the leaf nodes of the legal-move tree.
 *
 * The search walks the whole tree depth-first with copy-make. At depth 1 the
 * legal moves are counted without being played (bulk counting).
 */
module chessperft.perft;

import std.algorithm : sort;
import std.array : array;
import chessperft.movegen;
import chessperft.position;
import chessperft.types;

/// One line of a divide result: a root move and the leaf count beneath it.
struct DivideEntry
{
    /// The root move.
    Move move;
    /// Number of leaves reached through `move`, i.e. `perft(depth - 1)` after it.
    ulong nodes;
}

/**
 * Counts the leaf nodes reachable in exactly `depth` plies.
 * `perft(pos, 0) == 1`; positions with no legal moves contribute no nodes at
 * `depth >= 1`.
 */
ulong perft(const ref Position pos, uint depth) @safe pure nothrow @nogc
{
    if (depth == 0)
        return 1;
    if (depth == 1)
        return countLegalMoves(pos);

    MoveList list;
    generate(pos, list);
    ulong nodes = 0;
    foreach (m; list[])
    {
        Position next = pos;
        next.play(m);
        nodes += perft(next, depth - 1);
    }
    return nodes;
}

/**
 * Perft split by root move. `depth` must be at least 1. The entries are
 * sorted by the UCI text of the move (ASCII order), and the sum of their
 * `nodes` equals `perft(pos, depth)`.
 */
DivideEntry[] divide(const ref Position pos, uint depth) @safe
in (depth >= 1, "divide needs depth >= 1")
{
    DivideEntry[] result;
    const list = legalMoves(pos);
    foreach (m; list[])
    {
        Position next = pos;
        next.play(m);
        result ~= DivideEntry(m, perft(next, depth - 1));
    }
    result.sort!((a, b) => a.move.toString < b.move.toString);
    return result;
}

version (unittest)
{
    private ulong perftFen(string fen, uint depth)
    {
        const pos = Position.fromFen(fen);
        return perft(pos, depth);
    }

    private enum kiwipete = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
    private enum position3 = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1";
    private enum position4 = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1";
    private enum position5 = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8";
    private enum position6 = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10";
}

unittest
{
    assert(perftFen(startFen, 0) == 1);
    assert(perftFen(startFen, 1) == 20);
    assert(perftFen(startFen, 2) == 400);
    assert(perftFen(startFen, 3) == 8902);
    assert(perftFen(startFen, 4) == 197_281);
}

unittest
{
    assert(perftFen(kiwipete, 1) == 48);
    assert(perftFen(kiwipete, 2) == 2039);
    assert(perftFen(kiwipete, 3) == 97_862);
    assert(perftFen(kiwipete, 4) == 4_085_603);
}

unittest
{
    assert(perftFen(position3, 1) == 14);
    assert(perftFen(position3, 2) == 191);
    assert(perftFen(position3, 3) == 2812);
    assert(perftFen(position3, 4) == 43_238);
    assert(perftFen(position3, 5) == 674_624);
}

unittest
{
    assert(perftFen(position4, 1) == 6);
    assert(perftFen(position4, 2) == 264);
    assert(perftFen(position4, 3) == 9467);
    assert(perftFen(position4, 4) == 422_333);
}

unittest
{
    assert(perftFen(position5, 1) == 44);
    assert(perftFen(position5, 2) == 1486);
    assert(perftFen(position5, 3) == 62_379);
}

unittest
{
    assert(perftFen(position6, 1) == 46);
    assert(perftFen(position6, 2) == 2079);
    assert(perftFen(position6, 3) == 89_890);
}

unittest
{
    // Mirrored position 4 (colours swapped) must give the same counts.
    enum mirrored = "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1";
    assert(perftFen(mirrored, 1) == 6);
    assert(perftFen(mirrored, 2) == 264);
    assert(perftFen(mirrored, 3) == 9467);
}

unittest
{
    // Lone-king endings, including deep search with promotions.
    assert(perftFen("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", 3) == 0);
    assert(perftFen("8/P1k5/K7/8/8/8/8/8 w - - 0 1", 1) == 6);
}

unittest
{
    import std.algorithm : map, sum;

    const pos = Position.fromFen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    const d = divide(pos, 2);
    assert(d.length == 26);
    assert(d[0].move.toString == "a1a2" && d[0].nodes == 25);
    assert(d.map!(e => e.nodes).sum == 568);
    assert(perft(pos, 2) == 568);
    foreach (i; 1 .. d.length)
        assert(d[i - 1].move.toString < d[i].move.toString);
    // Divide at depth 1: every move leads to exactly one node.
    foreach (e; divide(pos, 1))
        assert(e.nodes == 1);
    // Positions without moves have empty divides.
    const stalemate = Position.fromFen("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1");
    assert(divide(stalemate, 3).length == 0);
}
