/**
 * The `.kiln-state` file: strict reader, canonical writer and the
 * freshness decision.
 */
module kiln.state;

import kiln.hash;
import kiln.paths;
import kiln.step;
import kiln.vfs;

import std.algorithm : sort;
import std.array : appender;

/// A path and the hash of the content that was read or written.
struct HashedPath
{
    string path;
    ulong hash;
}

/// What is remembered about one executed step.
final class StateEntry
{
    string cmd;
    HashedPath[] ins, deps, outs;
}

/// State entries keyed by primary output path.
alias State = StateEntry[string];

private bool parsePathHash(string rem, out HashedPath hp) @safe
{
    // exactly "<path> <hash>"
    size_t sp = rem.length;
    foreach (i, c; rem)
        if (c == ' ')
        {
            sp = i;
            break;
        }
    if (sp == rem.length)
        return false;
    auto path = rem[0 .. sp];
    ulong h;
    if (!isWorkspacePath(path) || !parseHex16(rem[sp + 1 .. $], h))
        return false;
    hp = HashedPath(path, h);
    return true;
}

/**
 * Parses a state file. Returns an empty state when the file is missing or
 * deviates from the grammar in any way.
 */
State parseState(Vfs vfs)
{
    State bad;
    if (!vfs.exists(stateFileName))
        return bad;
    string content = vfs.read(stateFileName);
    if (content.length == 0 || content[$ - 1] != '\n')
        return bad;

    State result;
    size_t pos = 0;
    bool first = true;
    // 0: expect step/EOF, 1: expect cmd, 2: in-section, 3: dep-section, 4: out-section
    int phase = 0;
    StateEntry cur;
    string key;
    while (pos < content.length)
    {
        size_t eol = pos;
        while (content[eol] != '\n')
            eol++;
        string line = content[pos .. eol];
        pos = eol + 1;
        if (first)
        {
            if (line != "kiln-state 1")
                return bad;
            first = false;
            continue;
        }
        if (line == "end")
        {
            if (phase != 4)
                return bad;
            if (key in result)
                return bad;
            if (cur.outs[0].path != key)
                return bad;
            result[key] = cur;
            phase = 0;
            continue;
        }
        if (line.length < 4)
            return bad;
        if (line[0 .. 4] == "cmd ")
        {
            if (phase != 1 || line.length == 4)
                return bad;
            cur.cmd = line[4 .. $];
            phase = 2;
        }
        else if (line[0 .. 4] == "dep ")
        {
            HashedPath hp;
            if (phase < 2 || phase > 3 || !parsePathHash(line[4 .. $], hp))
                return bad;
            cur.deps ~= hp;
            phase = 3;
        }
        else if (line[0 .. 3] == "in ")
        {
            HashedPath hp;
            if (phase != 2 || !parsePathHash(line[3 .. $], hp))
                return bad;
            cur.ins ~= hp;
        }
        else if (line[0 .. 4] == "out ")
        {
            HashedPath hp;
            if (phase < 2 || phase > 4 || !parsePathHash(line[4 .. $], hp))
                return bad;
            cur.outs ~= hp;
            phase = 4;
        }
        else if (line.length > 5 && line[0 .. 5] == "step ")
        {
            if (phase != 0)
                return bad;
            auto p = line[5 .. $];
            if (!isWorkspacePath(p))
                return bad;
            key = p;
            cur = new StateEntry;
            phase = 1;
        }
        else
            return bad;
    }
    if (first || phase != 0)
        return bad;
    return result;
}

/// Renders a state canonically: entries sorted by primary output.
string renderState(State state)
{
    auto keys = state.keys;
    keys.sort();
    auto app = appender!(char[]);
    app.put("kiln-state 1\n");
    foreach (k; keys)
    {
        auto e = state[k];
        app.put("step ");
        app.put(k);
        app.put("\ncmd ");
        app.put(e.cmd);
        app.put('\n');
        foreach (ref h; e.ins)
        {
            app.put("in ");
            app.put(h.path);
            app.put(' ');
            app.put(toHex16(h.hash));
            app.put('\n');
        }
        foreach (ref h; e.deps)
        {
            app.put("dep ");
            app.put(h.path);
            app.put(' ');
            app.put(toHex16(h.hash));
            app.put('\n');
        }
        foreach (ref h; e.outs)
        {
            app.put("out ");
            app.put(h.path);
            app.put(' ');
            app.put(toHex16(h.hash));
            app.put('\n');
        }
        app.put("end\n");
    }
    return (() @trusted => cast(string) app.data)();
}

private bool pathsMatch(const(HashedPath)[] recorded, const(string)[] actual) @safe
{
    if (recorded.length != actual.length)
        return false;
    foreach (i, ref h; recorded)
        if (h.path != actual[i])
            return false;
    return true;
}

private bool contentMatches(const(HashedPath)[] list, Vfs vfs)
{
    foreach (ref h; list)
        if (!vfs.exists(h.path) || vfs.hashOf(h.path) != h.hash)
            return false;
    return true;
}

/// Change detection: true iff `step` is fresh given its state entry `e`
/// (which may be null) and the current workspace.
bool isFresh(const StateEntry e, const Step step, Vfs vfs)
{
    if (e is null)
        return false;
    if (e.cmd != step.canon)
        return false;
    if (!pathsMatch(e.outs, step.fullOutputs))
        return false;
    if (!pathsMatch(e.ins, step.fileInputs))
        return false;
    return contentMatches(e.ins, vfs) && contentMatches(e.deps, vfs) && contentMatches(e.outs, vfs);
}
