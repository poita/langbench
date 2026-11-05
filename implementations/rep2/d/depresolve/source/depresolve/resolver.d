/**
 * The resolution search.
 *
 * Implements the SPEC's depth-first, newest-first, chronologically
 * backtracking search iteratively. The pending requirement list is a
 * persistent singly linked list in an arena that is truncated on backtrack;
 * chosen versions are undone through the frame stack. No state is copied per
 * step.
 */
module depresolve.resolver;

import std.algorithm.sorting : sort;
import std.array : appender;
import std.format : formattedWrite;

import depresolve.registry;
import depresolve.semver;

/// A package and the version picked for it.
struct Pick
{
    string name;
    Version version_;
}

/// The outcome of a resolution.
struct Resolution
{
    /// True if a complete solution exists.
    bool satisfiable;
    /// The chosen packages sorted by name (byte order). Empty if unsatisfiable.
    Pick[] picks;
}

/**
 * Run the search over `reg` and return the first solution in search order.
 *
 * Complexity: O(search steps + requirements prepended) after the O(R log V)
 * preprocessing done by `RegistryBuilder.build`; memory is proportional to the
 * longest search path. Worst-case time is exponential, as the problem allows.
 */
Resolution resolve(const Registry reg) pure @safe
{
    enum uint nil = uint.max;
    enum uint none = uint.max;

    struct Cell
    {
        uint req, next;
    }

    struct Frame
    {
        uint pkg;
        uint cursor, end; // candidate indices into the package's version list
        uint rest;        // pending list after this requirement
        uint mark;        // arena length when the frame was opened
    }

    // Hot state in locals.
    auto reqs = reg.reqs;
    auto versions = reg.versions;
    auto verStart = reg.verStart;
    auto chosen = new uint[reg.packageCount];
    chosen[] = none;
    auto arena = new Cell[](reg.reqs.length + 64);
    size_t arenaLen = 0;
    auto frames = new Frame[](64);
    size_t nFrames = 0;

    // Prepend the requirements of `e` (last first) to `tail`; return the head.
    uint pushReqs(VersionEntry e, uint tail) @safe
    {
        immutable need = arenaLen + e.reqCount;
        if (need > arena.length)
            arena.length = need > arena.length * 2 ? need : arena.length * 2;
        foreach_reverse (i; e.reqStart .. e.reqStart + e.reqCount)
        {
            arena[arenaLen] = Cell(i, tail);
            tail = cast(uint) arenaLen++;
        }
        return tail;
    }

    // Initial pending list: the root manifest.
    uint cur = pushReqs(VersionEntry(0, reg.rootStart, reg.rootCount), nil);

    bool fail = false;
    while (cur != nil)
    {
        immutable cell = arena[cur];
        immutable q = reqs[cell.req];
        immutable c = chosen[q.pkg];
        if (c != none)
        {
            if (c >= q.first && c < q.last)
            {
                cur = cell.next;
                continue;
            }
        }
        else if (q.first < q.last)
        {
            if (nFrames == frames.length)
                frames.length = frames.length * 2;
            frames[nFrames++] = Frame(q.pkg, q.first, q.last, cell.next, cast(uint) arenaLen);
            chosen[q.pkg] = q.first;
            cur = pushReqs(versions[verStart[q.pkg] + q.first], cell.next);
            continue;
        }

        // Backtrack: move the most recent frame with an untried candidate on.
        bool resumed = false;
        while (nFrames > 0)
        {
            auto f = &frames[nFrames - 1];
            arenaLen = f.mark;
            if (++f.cursor < f.end)
            {
                chosen[f.pkg] = f.cursor;
                cur = pushReqs(versions[verStart[f.pkg] + f.cursor], f.rest);
                resumed = true;
                break;
            }
            chosen[f.pkg] = none;
            --nFrames;
        }
        if (!resumed)
        {
            fail = true;
            break;
        }
    }

    Resolution result;
    if (fail)
        return result;
    result.satisfiable = true;
    result.picks = new Pick[nFrames];
    foreach (i; 0 .. nFrames)
    {
        immutable f = frames[i];
        result.picks[i] = Pick(reg.names[f.pkg],
            Version.fromKey(versions[verStart[f.pkg] + f.cursor].key));
    }
    result.picks.sort!((a, b) => a.name < b.name);
    return result;
}

/**
 * Format a resolution as the SPEC's output text: one `name version` line per
 * pick, or the single line `unsatisfiable`.
 */
string formatResolution(const Resolution r) pure @safe
{
    if (!r.satisfiable)
        return "unsatisfiable\n";
    auto buf = appender!string;
    foreach (p; r.picks)
        formattedWrite(buf, "%s %d.%d.%d\n", p.name, p.version_.major,
            p.version_.minor, p.version_.patch);
    return buf.data;
}
