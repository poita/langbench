/**
 * The persisted build state (`.kiln-state`): a strict reader that rejects
 * the whole file on any deviation, a canonical writer, and the freshness
 * decision.
 */
module kiln.state;

import kiln.bytes : startsWith;
import kiln.hash : hex16, parseHex16;
import kiln.model : Step;
import kiln.workspace : Workspace, isWorkspacePath, sortPaths;

/// A path and the hash of the content that was read or written.
struct HashedPath
{
    string path;
    ulong hash;
}

/// What the state records about one executed step.
struct StateEntry
{
    string cmd;
    HashedPath[] ins;
    HashedPath[] deps;
    HashedPath[] outs;
}

/// The whole state: entries keyed by primary output path.
final class BuildState
{
    StateEntry[string] entries;

    /// Removes the entry for `key`, if any.
    void remove(string key) @safe pure nothrow
    {
        entries.remove(key);
    }

    /// Adds or replaces the entry for `key`.
    void put(string key, StateEntry e) @safe pure nothrow
    {
        entries[key] = e;
    }
}

private bool parseHashed(string rest, out HashedPath hp) @safe pure nothrow
{
    // "<path> <16 hex digits>" with exactly one separating space.
    if (rest.length < 18)
        return false;
    immutable sp = rest.length - 17;
    if (rest[sp] != ' ')
        return false;
    auto path = rest[0 .. sp];
    ulong h;
    if (!isWorkspacePath(path) || !parseHex16(rest[sp + 1 .. $], h))
        return false;
    hp = HashedPath(path, h);
    return true;
}

/**
 * Parses state file text. Anything that does not match the grammar exactly
 * yields an empty state.
 */
BuildState parseState(string text) @safe pure
{
    auto st = new BuildState;
    if (!tryParse(text, st))
        return new BuildState;
    return st;
}

private bool tryParse(string text, BuildState st) @safe pure
{
    if (text.length == 0 || text[$ - 1] != '\n')
        return false;
    // Split at every LF; the final LF does not start another line.
    string[] lines;
    size_t start = 0;
    foreach (i; 0 .. text.length)
        if (text[i] == '\n')
        {
            lines ~= text[start .. i];
            start = i + 1;
        }
    if (lines.length == 0 || lines[0] != "kiln-state 1")
        return false;

    enum Phase
    {
        between,
        wantCmd,
        ins,
        deps,
        outs
    }

    Phase phase = Phase.between;
    string key;
    StateEntry cur;
    foreach (line; lines[1 .. $])
    {
        if (line == "end")
        {
            if (phase != Phase.outs)
                return false;
            if (cur.outs[0].path != key || key in st.entries)
                return false;
            st.entries[key] = cur;
            cur = StateEntry.init;
            phase = Phase.between;
            continue;
        }
        immutable sp = indexOfSpace(line);
        if (sp < 0)
            return false;
        auto word = line[0 .. sp];
        auto rest = line[sp + 1 .. $];
        switch (word)
        {
        case "step":
            if (phase != Phase.between || !isWorkspacePath(rest))
                return false;
            key = rest;
            phase = Phase.wantCmd;
            break;
        case "cmd":
            if (phase != Phase.wantCmd || rest.length == 0)
                return false;
            cur.cmd = rest;
            phase = Phase.ins;
            break;
        case "in":
            {
                HashedPath hp;
                if (phase != Phase.ins || !parseHashed(rest, hp))
                    return false;
                cur.ins ~= hp;
                break;
            }
        case "dep":
            {
                HashedPath hp;
                if ((phase != Phase.ins && phase != Phase.deps) || !parseHashed(rest, hp))
                    return false;
                cur.deps ~= hp;
                phase = Phase.deps;
                break;
            }
        case "out":
            {
                HashedPath hp;
                if (phase == Phase.between || phase == Phase.wantCmd || !parseHashed(rest, hp))
                    return false;
                cur.outs ~= hp;
                phase = Phase.outs;
                break;
            }
        default:
            return false;
        }
    }
    return phase == Phase.between;
}

private ptrdiff_t indexOfSpace(string s) @safe pure nothrow @nogc
{
    foreach (i; 0 .. s.length)
        if (s[i] == ' ')
            return cast(ptrdiff_t) i;
    return -1;
}

/// The canonical text of `st`: entries sorted by primary output.
string renderState(BuildState st) @safe pure
{
    char[] buf;
    buf ~= "kiln-state 1\n";
    auto keys = st.entries.keys;
    sortPaths(keys);
    foreach (k; keys)
    {
        auto e = st.entries[k];
        buf ~= "step ";
        buf ~= k;
        buf ~= "\ncmd ";
        buf ~= e.cmd;
        buf ~= '\n';
        void lines(string word, HashedPath[] hps)
        {
            foreach (ref hp; hps)
            {
                buf ~= word;
                buf ~= ' ';
                buf ~= hp.path;
                buf ~= ' ';
                buf ~= hex16(hp.hash);
                buf ~= '\n';
            }
        }

        lines("in", e.ins);
        lines("dep", e.deps);
        lines("out", e.outs);
        buf ~= "end\n";
    }
    return (() @trusted => cast(string) buf)();
}

private bool samePaths(const(HashedPath)[] a, const(string)[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (a[i].path != b[i])
            return false;
    return true;
}

private bool allCurrent(const(HashedPath)[] hps, Workspace ws) @safe pure nothrow
{
    foreach (ref hp; hps)
    {
        ulong h;
        if (!ws.hashOf(hp.path, h) || h != hp.hash)
            return false;
    }
    return true;
}

/// Decides whether `step` is fresh given its state `entry` (null if none).
bool isFresh(const Step step, const StateEntry* entry, Workspace ws) @safe pure nothrow
{
    if (entry is null)
        return false;
    if (entry.cmd != step.cmdString)
        return false;
    if (!samePaths(entry.outs, step.fullOuts))
        return false;
    if (!samePaths(entry.ins, step.fileInputs))
        return false;
    return allCurrent(entry.ins, ws) && allCurrent(entry.deps, ws) && allCurrent(entry.outs, ws);
}

@safe pure unittest
{
    enum good = "kiln-state 1\nstep out/a\ncmd write(\"x\")\nout out/a cbf29ce484222325\nend\n";
    auto st = parseState(good);
    assert(st.entries.length == 1 && st.entries["out/a"].cmd == "write(\"x\")");
    assert(renderState(st) == good);

    // Any deviation empties the state.
    assert(parseState("").entries.length == 0);
    assert(parseState("kiln-state 1").entries.length == 0); // unterminated
    assert(parseState("kiln-state 2\n").entries.length == 0);
    assert(parseState(good[0 .. $ - 4]).entries.length == 0); // missing end
    assert(parseState("kiln-state 1\nstep out/a\ncmd x\nend\n").entries.length == 0); // no out
    assert(parseState("kiln-state 1\nstep out/a\ncmd x\nout out/b cbf29ce484222325\nend\n")
            .entries.length == 0); // key mismatch
    assert(parseState("kiln-state 1\nstep out/a\ncmd x\nout out/a CBF29CE484222325\nend\n")
            .entries.length == 0); // uppercase hash
    assert(parseState("kiln-state 1\nstep out/a\ncmd x\nout out/a cbf29ce484222325\nin out/a cbf29ce484222325\nend\n")
            .entries.length == 0); // misordered
    assert(renderState(parseState("kiln-state 1\n")) == "kiln-state 1\n");
}
