/++
Perft (performance test) node counting and the divide breakdown.

The search is a plain single-threaded walk of the move tree: legal moves are
generated, played in place, recursed into and taken back. At depth 1 the
legal moves are only counted ("bulk counting").
+/
module chessperft.perft;

import std.algorithm.sorting : sort;

import chessperft.movegen;
import chessperft.move;
import chessperft.position;

/// Deepest search the move stack is sized for.
enum int maxDepth = 64;

/++
Count the leaf nodes of the legal-move tree of `pos` to `depth` plies.

`perft(pos, 0) == 1`. A position without legal moves (mate or stalemate)
contributes 0 for any `depth >= 1`. `pos` is restored before returning.
+/
ulong perft(ref Position pos, int depth) @trusted nothrow
{
    if (depth <= 0)
        return 1;
    if (depth == 1)
        return countLegal(pos);
    auto stack = new Move[maxMoves * depth];
    return perftImpl(pos, depth, stack.ptr);
}

/// One line of a divide result.
struct DivideEntry
{
    string move; /// UCI notation of the root move.
    ulong count; /// `perft(depth - 1)` after playing it.
}

/// Result of `divide`.
struct DivideResult
{
    DivideEntry[] entries; /// One entry per root move, sorted by move string (byte order).
    ulong total; /// Sum of the counts, equal to `perft(depth)`.
}

/++
Per-root-move node counts.
Params:
    pos = the root position; restored before returning
    depth = search depth, at least 1
+/
DivideResult divide(ref Position pos, int depth) @trusted nothrow
{
    DivideResult r;
    auto moves = legalMoves(pos);
    auto stack = new Move[maxMoves * (depth > 1 ? depth : 1)];
    r.entries.reserve(moves.length);
    foreach (m; moves)
    {
        ulong n = 1;
        if (depth > 1)
        {
            immutable u = pos.makeMove(m);
            n = perftImpl(pos, depth - 1, stack.ptr);
            pos.unmakeMove(m, u);
        }
        r.entries ~= DivideEntry(m.toString(), n);
        r.total += n;
    }
    r.entries.sort!((a, b) => a.move < b.move);
    return r;
}

private ulong perftImpl(ref Position pos, int depth, Move* stack) @system nothrow @nogc
{
    if (depth == 1)
        return countLegal(pos);
    immutable n = generateLegal(pos, stack);
    ulong nodes = 0;
    foreach (i; 0 .. n)
    {
        immutable m = stack[i];
        immutable u = pos.makeMove(m);
        nodes += perftImpl(pos, depth - 1, stack + n);
        pos.unmakeMove(m, u);
    }
    return nodes;
}
