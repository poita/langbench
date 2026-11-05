/// The `.kiln-state` file: strict reader, canonical writer, freshness test.
module kiln.state;

import std.algorithm.sorting : sort;
import kiln.bytes;
import kiln.hash : hex16;
import kiln.paths : isWorkspacePath;
import kiln.plan : StepDef;
import kiln.vfs : Vfs;

/// A path with the hash of the content seen.
struct PathHash
{
    string path;
    ulong hash;
}

/// The recorded state of one executed step.
struct Entry
{
    string key;      /// primary output path
    string cmd;      /// canonical command string
    PathHash[] ins;
    PathHash[] deps;
    PathHash[] outs;
}

/// All entries, keyed by primary output path.
alias State = Entry[string];

private bool parseHash(const(char)[] s, out ulong h) @safe pure nothrow @nogc
{
    if (s.length != 16)
        return false;
    h = 0;
    foreach (c; s)
    {
        uint d;
        if (c >= '0' && c <= '9')
            d = c - '0';
        else if (c >= 'a' && c <= 'f')
            d = c - 'a' + 10;
        else
            return false;
        h = (h << 4) | d;
    }
    return true;
}

/// "<path> <hash>" remainder of an `in`/`dep`/`out` line.
private bool parsePathHash(string rem, out PathHash ph) @safe pure nothrow @nogc
{
    if (rem.length < 18 || rem[$ - 17] != ' ')
        return false;
    auto path = rem[0 .. $ - 17];
    if (!isWorkspacePath(path) || !parseHash(rem[$ - 16 .. $], ph.hash))
        return false;
    ph.path = path;
    return true;
}

/// Parse a state file. Any deviation from the grammar yields an empty state.
State parseState(string text)
{
    State st;
    if (text.length == 0 || text[$ - 1] != '\n')
        return null;
    size_t pos = 0;
    immutable n = text.length;
    // returns the next line (without '\n'), advancing pos
    string nextLine()
    {
        size_t e = pos;
        while (e < n && text[e] != '\n')
            ++e;
        auto l = text[pos .. e];
        pos = e + 1;
        return l;
    }
    if (nextLine() != "kiln-state 1")
        return null;
    while (pos < n)
    {
        auto line = nextLine();
        if (!startsWithBytes(line, "step "))
            return null;
        Entry e;
        e.key = line[5 .. $];
        if (!isWorkspacePath(e.key) || e.key in st)
            return null;
        // cmd
        if (pos >= n)
            return null;
        line = nextLine();
        if (!startsWithBytes(line, "cmd ") || line.length == 4)
            return null;
        e.cmd = line[4 .. $];
        int section = 0; // 0 = in, 1 = dep, 2 = out
        bool ended = false;
        while (pos < n)
        {
            line = nextLine();
            if (line == "end")
            {
                ended = true;
                break;
            }
            PathHash ph;
            if (startsWithBytes(line, "in "))
            {
                if (section > 0 || !parsePathHash(line[3 .. $], ph))
                    return null;
                e.ins ~= ph;
            }
            else if (startsWithBytes(line, "dep "))
            {
                if (section > 1 || !parsePathHash(line[4 .. $], ph))
                    return null;
                section = 1;
                e.deps ~= ph;
            }
            else if (startsWithBytes(line, "out "))
            {
                if (!parsePathHash(line[4 .. $], ph))
                    return null;
                section = 2;
                e.outs ~= ph;
            }
            else
                return null;
        }
        if (!ended || e.outs.length == 0 || e.outs[0].path != e.key)
            return null;
        st[e.key] = e;
    }
    return st;
}

/// Serialise a state: header, then entries sorted by key.
string writeState(const State st)
{
    Buf b;
    b.put("kiln-state 1\n");
    auto keys = st.keys;
    keys.sort();
    foreach (k; keys)
    {
        auto e = st[k];
        b.put("step ");
        b.put(e.key);
        b.put("\ncmd ");
        b.put(e.cmd);
        b.putc('\n');
        foreach (ref x; e.ins)
            putPH(b, "in ", x);
        foreach (ref x; e.deps)
            putPH(b, "dep ", x);
        foreach (ref x; e.outs)
            putPH(b, "out ", x);
        b.put("end\n");
    }
    return b.take();
}

private void putPH(ref Buf b, string key, const ref PathHash ph)
{
    b.put(key);
    b.put(ph.path);
    b.putc(' ');
    b.put(hex16(ph.hash));
    b.putc('\n');
}

private bool samePaths(const(PathHash)[] recorded, const(string)[] paths) @safe pure nothrow @nogc
{
    if (recorded.length != paths.length)
        return false;
    foreach (i; 0 .. paths.length)
        if (recorded[i].path != paths[i])
            return false;
    return true;
}

private bool allCurrent(const(PathHash)[] recorded, Vfs vfs)
{
    foreach (ref x; recorded)
        if (!vfs.exists(x.path) || vfs.hashOf(x.path) != x.hash)
            return false;
    return true;
}

/// Decide whether `step` is fresh against `entry` (null = no entry) and the
/// current workspace, per the seven change-detection rules.
bool isFresh(const(Entry)* entry, StepDef step, Vfs vfs)
{
    if (entry is null)
        return false;
    if (entry.cmd != step.canon)
        return false;
    if (!samePaths(entry.outs, step.fullOutputs()))
        return false;
    if (!samePaths(entry.ins, step.fileInputs))
        return false;
    return allCurrent(entry.ins, vfs) && allCurrent(entry.deps, vfs) && allCurrent(entry.outs, vfs);
}
