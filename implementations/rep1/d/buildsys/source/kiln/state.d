/// The `.kiln-state` file: strict reader, canonical writer, freshness decision.
module kiln.state;

import std.algorithm.sorting : sort;

import kiln.hash;
import kiln.paths;
import kiln.step;
import kiln.vfs;

/// A `(path, hash)` pair from an `in`, `dep` or `out` line.
struct StateItem
{
    string path;
    ulong hash;
}

/// What is known about one previously executed step.
struct StateEntry
{
    string cmd; /// canonical command string
    StateItem[] ins;
    StateItem[] deps;
    StateItem[] outs;
}

/// The whole state, keyed by primary output path.
alias State = StateEntry[string];

private bool parseItem(string rest, out StateItem item) @safe
{
    size_t k = 0;
    while (k < rest.length && rest[k] != ' ')
        ++k;
    if (k == rest.length)
        return false;
    const path = rest[0 .. k];
    if (!isWorkspacePath(path))
        return false;
    ulong h;
    if (!parseHex16(rest[k + 1 .. $], h))
        return false;
    item = StateItem(path, h);
    return true;
}

private bool startsWith(string s, string p) @safe
{
    return s.length >= p.length && s[0 .. p.length] == p;
}

/// Parses a state file. Any deviation from the grammar yields an empty state.
State parseState(string content) @safe
{
    State result;
    if (content.length == 0 || content[$ - 1] != '\n')
        return null;
    size_t pos = 0;
    bool more = true;

    string nextLine()
    {
        size_t e = pos;
        while (content[e] != '\n')
            ++e;
        auto l = content[pos .. e];
        pos = e + 1;
        more = pos < content.length;
        return l;
    }

    if (nextLine() != "kiln-state 1")
        return null;
    while (more)
    {
        auto l = nextLine();
        if (!startsWith(l, "step "))
            return null;
        const key = l[5 .. $];
        if (!isWorkspacePath(key) || key in result)
            return null;
        if (!more)
            return null;
        l = nextLine();
        if (!startsWith(l, "cmd ") || l.length == 4)
            return null;
        StateEntry e;
        e.cmd = l[4 .. $];
        int stage = 0; // 0 = ins, 1 = deps, 2 = outs
        bool ended = false;
        while (more)
        {
            l = nextLine();
            if (l == "end")
            {
                ended = true;
                break;
            }
            StateItem it;
            if (startsWith(l, "in "))
            {
                if (stage != 0 || !parseItem(l[3 .. $], it))
                    return null;
                e.ins ~= it;
            }
            else if (startsWith(l, "dep "))
            {
                if (stage > 1 || !parseItem(l[4 .. $], it))
                    return null;
                stage = 1;
                e.deps ~= it;
            }
            else if (startsWith(l, "out "))
            {
                if (!parseItem(l[4 .. $], it))
                    return null;
                stage = 2;
                e.outs ~= it;
            }
            else
                return null;
        }
        if (!ended || e.outs.length == 0 || e.outs[0].path != key)
            return null;
        result[key] = e;
    }
    return result;
}

/// Renders the state in canonical form (entries sorted by primary output).
string renderState(const State st) @safe
{
    auto keys = st.keys;
    keys.sort();
    char[] b;
    b ~= "kiln-state 1\n";
    void items(string tag, const(StateItem)[] xs)
    {
        foreach (ref x; xs)
        {
            b ~= tag;
            b ~= ' ';
            b ~= x.path;
            b ~= ' ';
            b ~= toHex16(x.hash);
            b ~= '\n';
        }
    }

    foreach (k; keys)
    {
        const e = st[k];
        b ~= "step ";
        b ~= k;
        b ~= "\ncmd ";
        b ~= e.cmd;
        b ~= '\n';
        items("in", e.ins);
        items("dep", e.deps);
        items("out", e.outs);
        b ~= "end\n";
    }
    return (() @trusted => cast(string) b)();
}

private bool samePaths(const(StateItem)[] items, const(string)[] paths) @safe
{
    if (items.length != paths.length)
        return false;
    foreach (i; 0 .. items.length)
        if (items[i].path != paths[i])
            return false;
    return true;
}

private bool hashesMatch(const(StateItem)[] items, Vfs vfs) @safe
{
    foreach (ref it; items)
        if (!vfs.exists(it.path) || vfs.hash(it.path) != it.hash)
            return false;
    return true;
}

/// Decides whether `step` is fresh given its state entry `e` (null if none).
bool isFresh(const Step step, const(StateEntry)* e, Vfs vfs) @safe
{
    if (e is null)
        return false;
    if (e.cmd != step.canonical)
        return false;
    if (!samePaths(e.outs, step.fullOutputs))
        return false;
    if (!samePaths(e.ins, step.fileInputs))
        return false;
    return hashesMatch(e.ins, vfs) && hashesMatch(e.deps, vfs) && hashesMatch(e.outs, vfs);
}
