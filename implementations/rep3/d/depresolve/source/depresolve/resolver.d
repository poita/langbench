/**
 * The resolution search.
 *
 * Implements the depth-first, newest-first, chronologically backtracking
 * search iteratively: an explicit stack of choice-point frames, a `chosen`
 * array indexed by package id, and the pending requirement list kept as a
 * persistent singly linked list in an arena that is truncated on backtrack.
 * Nothing is copied per step.
 */
module depresolve.resolver;

import std.algorithm : sort;
import depresolve.registry;
import depresolve.semver;

/// One package picked by a successful resolution.
struct Pick
{
    /// Package name.
    string name;
    /// Chosen version.
    Version version_;
}

/// The outcome of a resolution.
struct Resolution
{
    /// True when a complete resolution was found.
    bool satisfiable;
    /// The picked packages sorted by name (byte order); empty when unsatisfiable.
    Pick[] picks;
}

private enum noCell = -1;
private enum notChosen = -1;

private struct Cell
{
    uint req;
    int next;
}

private struct Frame
{
    uint pkg;
    uint cursor; // position in Registry.versions of the current candidate
    uint end;    // one past the last candidate
    int rest;    // pending list after this package's own requirements
    uint mark;   // arena length when the frame was opened
}

/**
 * Resolves the root manifest of `reg` and returns the first solution of the
 * specified search order, or an unsatisfiable `Resolution`.
 */
Resolution resolve(const Registry reg) pure @safe
{
    const reqs = reg.reqs;
    const versions = reg.versions;
    const reqStart = reg.reqStart;
    const reqCount = reg.reqCount;

    auto chosen = new int[reg.names.length];
    chosen[] = notChosen;
    auto arena = new Cell[1024];
    size_t arenaLen = 0;
    auto frames = new Frame[256];
    size_t nFrames = 0;

    // Pushes the requirements [start, start + count) in front of `tail`.
    int prepend(uint start, uint count, int tail) @safe pure nothrow
    {
        if (arenaLen + count > arena.length)
        {
            size_t cap = arena.length * 2;
            while (cap < arenaLen + count)
                cap *= 2;
            arena.length = cap;
        }
        foreach_reverse (i; 0 .. count)
        {
            arena[arenaLen] = Cell(start + i, tail);
            tail = cast(int) arenaLen++;
        }
        return tail;
    }

    int cur = prepend(reg.rootStart, reg.rootCount, noCell);
    bool failed = false;

    while (cur != noCell)
    {
        const cell = arena[cur];
        const q = &reqs[cell.req];
        const c = chosen[q.pkg];
        bool backtrack = false;
        if (c != notChosen)
        {
            if (c >= q.first && c < q.last)
            {
                cur = cell.next;
                continue;
            }
            backtrack = true;
        }
        else if (q.last <= q.first)
            backtrack = true;
        else
        {
            if (nFrames == frames.length)
                frames.length = frames.length * 2;
            frames[nFrames++] = Frame(q.pkg, q.first, q.last, cell.next, cast(uint) arenaLen);
            chosen[q.pkg] = cast(int) q.first;
            cur = prepend(reqStart[q.first], reqCount[q.first], cell.next);
            continue;
        }

        // Backtrack to the most recent frame with an untried candidate.
        assert(backtrack);
        while (true)
        {
            if (nFrames == 0)
            {
                failed = true;
                break;
            }
            auto f = &frames[nFrames - 1];
            if (f.cursor + 1 < f.end)
            {
                ++f.cursor;
                chosen[f.pkg] = cast(int) f.cursor;
                arenaLen = f.mark;
                cur = prepend(reqStart[f.cursor], reqCount[f.cursor], f.rest);
                break;
            }
            chosen[f.pkg] = notChosen;
            --nFrames;
        }
        if (failed)
            break;
    }

    Resolution result;
    if (failed)
        return result;
    result.satisfiable = true;
    result.picks = new Pick[nFrames];
    foreach (i, ref f; frames[0 .. nFrames])
        result.picks[i] = Pick(reg.names[f.pkg], versions[f.cursor]);
    result.picks.sort!((a, b) => a.name < b.name);
    return result;
}
