/**
 * The persisted build state (`.kiln-state`) and change detection.
 */
module kiln.state;

import kiln.hash;
import kiln.step;
import kiln.text;
import kiln.vfs;

/// A path with the hash of the content recorded for it.
struct PathHash
{
    ///
    string path;
    ///
    ulong hash;
}

/// The recorded knowledge about one previously executed step.
struct StateEntry
{
    /// Primary output path.
    string key;
    /// Canonical command string.
    string cmd;
    ///
    PathHash[] ins, deps, outs;
}

/// The whole state: entries keyed by primary output.
final class State
{
    ///
    StateEntry[string] entries;

    /// Reads state text; any deviation from the grammar yields an empty state.
    static State parse(string content)
    {
        auto st = new State;
        if (!tryParse(content, st.entries))
            st.entries = null;
        return st;
    }

    /// Writes the canonical text: entries sorted by key.
    string serialize() const
    {
        import std.algorithm.sorting : sort;

        string r = "kiln-state 1\n";
        auto keys = entries.keys;
        keys.sort!((a, b) => cmpBytes(a, b) < 0);
        foreach (k; keys)
        {
            const e = entries[k];
            r ~= "step " ~ e.key ~ "\ncmd " ~ e.cmd ~ "\n";
            foreach (ref p; e.ins)
                r ~= "in " ~ p.path ~ " " ~ toHex16(p.hash) ~ "\n";
            foreach (ref p; e.deps)
                r ~= "dep " ~ p.path ~ " " ~ toHex16(p.hash) ~ "\n";
            foreach (ref p; e.outs)
                r ~= "out " ~ p.path ~ " " ~ toHex16(p.hash) ~ "\n";
            r ~= "end\n";
        }
        return r;
    }

    /// Decides whether `step` is fresh against this state and `fs`.
    bool isFresh(Step step, Vfs fs) const
    {
        auto ep = step.primary in entries;
        if (ep is null)
            return false;
        const e = *ep;
        if (e.cmd != step.cmdString)
            return false;
        if (e.outs.length != step.fullOuts.length || e.ins.length != step.fileInputs.length)
            return false;
        foreach (i, ref p; e.outs)
            if (p.path != step.fullOuts[i])
                return false;
        foreach (i, ref p; e.ins)
            if (p.path != step.fileInputs[i])
                return false;
        foreach (list; [e.ins, e.deps, e.outs])
            foreach (ref p; list)
            {
                ulong h;
                if (!fs.hashOf(p.path, h) || h != p.hash)
                    return false;
            }
        return true;
    }
}

private bool prefixed(string line, string key, out string rest) @safe pure nothrow @nogc
{
    if (line.length > key.length + 1 && startsWithBytes(line, key) && line[key.length] == ' ')
    {
        rest = line[key.length + 1 .. $];
        return true;
    }
    return false;
}

private bool parsePathHash(string rest, out PathHash ph) @safe pure nothrow @nogc
{
    foreach (i, char c; rest)
    {
        if (c == ' ')
        {
            const path = rest[0 .. i];
            if (!isWorkspacePath(path))
                return false;
            ulong h;
            if (!parseHex16(rest[i + 1 .. $], h))
                return false;
            ph = PathHash(path, h);
            return true;
        }
    }
    return false;
}

private bool tryParse(string content, ref StateEntry[string] entries)
{
    if (content.length == 0 || content[$ - 1] != '\n')
        return false;
    auto lines = splitLines(content);
    if (lines.length == 0 || lines[0] != "kiln-state 1")
        return false;
    size_t i = 1;
    while (i < lines.length)
    {
        StateEntry e;
        string rest;
        if (!prefixed(lines[i], "step", rest) || !isWorkspacePath(rest))
            return false;
        e.key = rest;
        ++i;
        if (i >= lines.length || !prefixed(lines[i], "cmd", rest))
            return false;
        e.cmd = rest;
        ++i;
        PathHash ph;
        while (i < lines.length && prefixed(lines[i], "in", rest))
        {
            if (!parsePathHash(rest, ph))
                return false;
            e.ins ~= ph;
            ++i;
        }
        while (i < lines.length && prefixed(lines[i], "dep", rest))
        {
            if (!parsePathHash(rest, ph))
                return false;
            e.deps ~= ph;
            ++i;
        }
        while (i < lines.length && prefixed(lines[i], "out", rest))
        {
            if (!parsePathHash(rest, ph))
                return false;
            e.outs ~= ph;
            ++i;
        }
        if (e.outs.length == 0 || i >= lines.length || lines[i] != "end")
            return false;
        ++i;
        if (e.outs[0].path != e.key || e.key in entries)
            return false;
        entries[e.key] = e;
    }
    return true;
}

unittest
{
    enum good = "kiln-state 1\nstep out/a\ncmd write(\"a b\")\nin src/x 0000000000000001\n"
        ~ "dep src/y 0000000000000002\nout out/a 0000000000000003\nend\n";
    auto st = State.parse(good);
    assert(st.entries.length == 1 && st.entries["out/a"].cmd == "write(\"a b\")");
    assert(st.serialize() == good);
    assert(State.parse("kiln-state 1\n").entries.length == 0);
}

unittest
{
    void bad(string s)
    {
        assert(State.parse(s).entries.length == 0, s);
    }

    enum h = " 0000000000000001";
    bad("");
    bad("kiln-state 1"); // not newline terminated
    bad("kiln-state 2\n");
    bad("kiln-state 1\nstep out/a\ncmd x\nout out/a" ~ h ~ "\n"); // unterminated entry
    bad("kiln-state 1\nstep out/a\ncmd x\nend\n"); // no out
    bad("kiln-state 1\nstep out/a\nout out/a" ~ h ~ "\nend\n"); // no cmd
    bad("kiln-state 1\nstep out/a\ncmd \nout out/a" ~ h ~ "\nend\n"); // empty cmd
    bad("kiln-state 1\nstep out/a\ncmd x\nout out/b" ~ h ~ "\nend\n"); // key mismatch
    bad("kiln-state 1\nstep out/a\ncmd x\ndep a" ~ h ~ "\nin a" ~ h ~ "\nout out/a" ~ h ~ "\nend\n"); // order
    bad("kiln-state 1\nstep out/a\ncmd x\nout out/a 000000000000000G\nend\n");
    bad("kiln-state 1\nstep out/a\ncmd x\nout out/a" ~ h ~ "\nend\nstep out/a\ncmd x\nout out/a" ~ h ~ "\nend\n");
    bad("kiln-state 1\nstep out/a\ncmd x\nout out/a" ~ h ~ "\nend\nstray\n");
    bad("kiln-state 1\nstep out/a\ncmd x\nout  out/a" ~ h ~ "\nend\n");
}
