/**
 * The text query format used by the command-line tool: one line per query,
 * either `<fen> <depth>` (a perft count) or `<fen> divide <depth>`.
 */
module chessperft.query;

import std.array : appender, join, split;
import std.conv : to;
import std.string : stripRight;
import chessperft.perft;
import chessperft.position;

/// A parsed query line.
struct Query
{
    /// The position to search from.
    Position position;
    /// Search depth in plies.
    uint depth;
    /// Whether per-move counts are wanted (`divide`) rather than a single total.
    bool isDivide;
}

/**
 * Parses a query line: six FEN fields, an optional `divide` keyword, a depth.
 * Throws: `FenException` or `ConvException` if the line is malformed.
 */
Query parseQuery(const(char)[] line) @safe
{
    const fields = line.idup.stripRight("\r\n").split(' ');
    if (fields.length != 7 && fields.length != 8)
        throw new FenException("query needs 7 or 8 fields: " ~ line.idup);
    Query q;
    q.isDivide = fields.length == 8;
    if (q.isDivide && fields[6] != "divide")
        throw new FenException("expected 'divide': " ~ fields[6]);
    q.position = Position.fromFen(fields[0 .. 6].join(" "));
    q.depth = fields[$ - 1].to!uint;
    if (q.isDivide && q.depth < 1)
        throw new FenException("divide needs depth >= 1");
    return q;
}

/**
 * Answers a query as output text, each line terminated by `\n`: either the
 * perft count, or one `<move> <count>` line per root move (sorted) followed
 * by `total <n>`.
 */
string answer(const ref Query q) @safe
{
    if (!q.isDivide)
        return perft(q.position, q.depth).to!string ~ "\n";
    auto output = appender!string;
    ulong total = 0;
    foreach (e; divide(q.position, q.depth))
    {
        output ~= e.move.toString;
        output ~= ' ';
        output ~= e.nodes.to!string;
        output ~= '\n';
        total += e.nodes;
    }
    output ~= "total ";
    output ~= total.to!string;
    output ~= '\n';
    return output[];
}

/// Parses and answers one query line.
string answerLine(const(char)[] line) @safe
{
    const q = parseQuery(line);
    return answer(q);
}

unittest
{
    assert(answerLine("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 1") == "20\n");
    assert(answerLine("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3") == "8902\n");
    assert(answerLine("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1 0") == "1\n");
}

unittest
{
    assert(answerLine("8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1")
        == "a6a5 1\na6b5 1\na7a8b 1\na7a8n 1\na7a8q 1\na7a8r 1\ntotal 6\n");
    assert(answerLine("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3") == "total 0\n");
}

unittest
{
    import std.exception : assertThrown;

    const q = parseQuery("8/8/8/8/8/8/8/K6k b - - 3 17 divide 5");
    assert(q.isDivide && q.depth == 5 && q.position.side == Color.black);
    assert(!parseQuery("8/8/8/8/8/8/8/K6k b - - 3 17 2").isDivide);
    assertThrown!FenException(parseQuery("8/8/8/8/8/8/8/K6k b - - 3 17"));
    assertThrown!FenException(parseQuery("8/8/8/8/8/8/8/K6k b - - 3 17 foo 2"));
    assertThrown!FenException(parseQuery("8/8/8/8/8/8/8/K6k b - - 3 17 divide 0"));
}

private import chessperft.types : Color;
