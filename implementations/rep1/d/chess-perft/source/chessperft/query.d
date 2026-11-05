/++
The line-oriented query protocol used by the command-line tool.

A query line is a FEN record (six fields) followed by either a depth
(`perft`) or the word `divide` and a depth. See `README.md` for the format.
+/
module chessperft.query;

import std.array : split;
import std.conv : to;
import std.range.primitives : isOutputRange, put;

import chessperft.perft;
import chessperft.position;

/// A parsed query.
struct Query
{
    Position position; /// The position to search from.
    bool isDivide; /// Whether a per-move breakdown is requested.
    int depth; /// Search depth.
}

/++
Parse one query line.
Throws: `FenException` or `std.conv.ConvException` if the line is malformed.
+/
Query parseQuery(const(char)[] line)
{
    auto f = line.split(' ');
    Query q;
    if (f.length == 8 && f[6] == "divide")
        q.isDivide = true;
    else if (f.length != 7)
        throw new FenException("query must have 7 fields, or 8 with `divide`");
    q.position = Position.fromFields(f[0], f[1], f[2], f[3]);
    q.depth = f[$ - 1].to!int;
    if (q.depth < 0 || (q.isDivide && q.depth < 1))
        throw new FenException("bad depth");
    return q;
}

/++
Answer a query, writing the result lines (each terminated by `\n`) to `sink`.
+/
void answer(Sink)(ref Sink sink, Query q) if (isOutputRange!(Sink, const(char)[]))
{
    if (!q.isDivide)
    {
        sink.put(perft(q.position, q.depth).to!string);
        sink.put("\n");
        return;
    }
    auto r = divide(q.position, q.depth);
    foreach (e; r.entries)
    {
        sink.put(e.move);
        sink.put(" ");
        sink.put(e.count.to!string);
        sink.put("\n");
    }
    sink.put("total ");
    sink.put(r.total.to!string);
    sink.put("\n");
}

/++
Answer every non-empty line of `input` in order and return all output as one string.
Throws: as `parseQuery`.
+/
string answerAll(const(char)[] input)
{
    import std.array : appender;

    auto o = appender!string;
    size_t start = 0;
    foreach (i; 0 .. input.length + 1)
        if (i == input.length || input[i] == '\n')
        {
            auto line = input[start .. i];
            start = i + 1;
            if (line.length && line[$ - 1] == '\r')
                line = line[0 .. $ - 1];
            if (line.length)
                answer(o, parseQuery(line));
        }
    return o.data;
}
