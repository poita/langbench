/**
 * The resolution search.
 *
 * Implements the specified depth-first, newest-first, chronologically
 * backtracking search iteratively: an explicit frame stack of choice
 * points, a `chosen` array indexed by package id, and the pending
 * requirements kept as a persistent singly linked list in an arena that is
 * truncated on backtrack. Nothing is copied per step.
 */
module depresolve.resolver;

import depresolve.registry;
import depresolve.semver;

/// One package picked by the resolver.
struct Choice
{
    string name;
    VersionKey version_;

    /// The chosen version as `MAJOR.MINOR.PATCH`.
    string versionString() const @safe pure
    {
        return formatVersion(version_);
    }
}

/// Outcome of a resolution.
struct Resolution
{
    /// True when a complete solution exists.
    bool satisfiable;
    /// The chosen packages sorted by name (byte order); empty when unsatisfiable.
    Choice[] choices;
}

private struct Frame
{
    uint pkg;
    uint cursor; // current candidate index in the package's newest-first list
    uint end; // one past the last admissible candidate index
    int rest; // pending-list cell following the requirement that opened it
    uint mark; // arena length when the frame was opened
}

/**
 * Resolves the root manifest of `reg` against its registry and returns the
 * first solution in the specified search order, or an unsatisfiable result.
 */
Resolution resolve(const ref Registry reg) @trusted
{
    import core.stdc.stdlib : free, malloc, realloc;

    enum int nil = -1;
    const nPkg = reg.names.length;

    // Read-only registry data bound to locals.
    const reqs = reg.requirements.ptr;
    const vers = reg.versions.ptr;
    const cands = reg.candidates.ptr;
    const pkgStart = reg.pkgStart.ptr;

    auto chosen = new uint[nPkg];
    chosen[] = none;

    // Arena of pending cells: (requirement index, next cell).
    size_t arenaCap = 1 << 12;
    auto cellReq = cast(uint*) malloc(uint.sizeof * arenaCap);
    auto cellNext = cast(int*) malloc(int.sizeof * arenaCap);
    size_t arenaLen = 0;

    size_t frameCap = 1 << 8;
    auto frames = cast(Frame*) malloc(Frame.sizeof * frameCap);
    size_t nFrames = 0;
    scope (exit)
    {
        free(cellReq);
        free(cellNext);
        free(frames);
    }

    // Prepends requirement slice [start, start+count) to `head`, last first.
    // (Inlined as a nested function; captures arena state.)
    int prepend(uint start, uint count, int head)
    {
        if (arenaLen + count > arenaCap)
        {
            while (arenaLen + count > arenaCap)
                arenaCap *= 2;
            cellReq = cast(uint*) realloc(cellReq, uint.sizeof * arenaCap);
            cellNext = cast(int*) realloc(cellNext, int.sizeof * arenaCap);
        }
        foreach_reverse (i; 0 .. count)
        {
            cellReq[arenaLen] = start + i;
            cellNext[arenaLen] = head;
            head = cast(int) arenaLen;
            ++arenaLen;
        }
        return head;
    }

    int head = prepend(reg.rootStart, reg.rootCount, nil);
    bool failed = false;

    mainLoop: while (head != nil)
    {
        const r = &reqs[cellReq[head]];
        const rest = cellNext[head];
        const pkg = r.pkg;
        const cur = chosen[pkg];

        if (cur != none)
        {
            if (cur >= r.first && cur < r.last)
            {
                head = rest;
                continue;
            }
            // violated: fall through to backtracking
        }
        else if (r.first < r.last)
        {
            if (nFrames == frameCap)
            {
                frameCap *= 2;
                frames = cast(Frame*) realloc(frames, Frame.sizeof * frameCap);
            }
            frames[nFrames++] = Frame(pkg, r.first, r.last, rest, cast(uint) arenaLen);
            chosen[pkg] = r.first;
            const v = &vers[cands[pkgStart[pkg] + r.first]];
            head = prepend(v.reqStart, v.reqCount, rest);
            continue;
        }

        // Backtrack to the most recent frame with an untried candidate.
        while (true)
        {
            if (nFrames == 0)
            {
                failed = true;
                break mainLoop;
            }
            Frame* f = &frames[nFrames - 1];
            ++f.cursor;
            if (f.cursor < f.end)
            {
                chosen[f.pkg] = f.cursor;
                arenaLen = f.mark;
                const v = &vers[cands[pkgStart[f.pkg] + f.cursor]];
                head = prepend(v.reqStart, v.reqCount, f.rest);
                continue mainLoop;
            }
            chosen[f.pkg] = none;
            --nFrames;
        }
    }

    Resolution result;
    if (failed)
        return result;
    result.satisfiable = true;
    result.choices = new Choice[nFrames];
    foreach (i; 0 .. nFrames)
    {
        const f = frames[i];
        const v = vers[cands[pkgStart[f.pkg] + f.cursor]];
        result.choices[i] = Choice(reg.names[f.pkg], v.key);
    }
    import std.algorithm.sorting : sort;

    result.choices.sort!((a, b) => a.name < b.name);
    return result;
}

/// Convenience: parses `input` and resolves it.
Resolution resolveText(const(char)[] input) @safe
{
    auto reg = parseRegistry(input);
    return () @trusted { return resolve(reg); }();
}

/// Formats a resolution as the CLI output: `name version` lines, or `unsatisfiable`.
string formatResolution(const ref Resolution res) @safe pure
{
    import std.array : appender;

    if (!res.satisfiable)
        return "unsatisfiable\n";
    auto buf = appender!string();
    foreach (c; res.choices)
    {
        buf.put(c.name);
        buf.put(' ');
        buf.put(c.versionString);
        buf.put('\n');
    }
    return buf.data;
}
