/// The sixteen built-in commands and their pure, in-process execution.
module kiln.commands;

import std.algorithm.sorting : sort;

import kiln.bytes;
import kiln.errors;
import kiln.paths : isWorkspacePath;
import kiln.value;
import kiln.vfs;
import kiln.hash : toHex16;

/// Identifier of a built-in command.
enum CmdId : ubyte
{
    write,
    copy,
    concat,
    upper,
    lower,
    grep,
    replace,
    sort_lines,
    reverse_lines,
    dedup,
    number,
    indent,
    wrap,
    count_lines,
    hash,
    preprocess
}

/// Static description of a command.
struct CmdInfo
{
    string name;
    CmdId id;
    string sig; /// argument kinds: `s` = str, `i` = int
    int minIn; /// minimum file inputs
    int maxIn; /// maximum file inputs (-1 = unbounded)
    bool depfile; /// whether the command requires a depfile
    long cost; /// default cost
}

private immutable CmdInfo[] cmdTable = [
    CmdInfo("write", CmdId.write, "s", 0, 0, false, 1),
    CmdInfo("copy", CmdId.copy, "", 1, 1, false, 1),
    CmdInfo("concat", CmdId.concat, "", 1, -1, false, 2),
    CmdInfo("upper", CmdId.upper, "", 1, 1, false, 2),
    CmdInfo("lower", CmdId.lower, "", 1, 1, false, 2),
    CmdInfo("grep", CmdId.grep, "s", 1, 1, false, 3),
    CmdInfo("replace", CmdId.replace, "ss", 1, 1, false, 3),
    CmdInfo("sort_lines", CmdId.sort_lines, "", 1, 1, false, 4),
    CmdInfo("reverse_lines", CmdId.reverse_lines, "", 1, 1, false, 2),
    CmdInfo("dedup", CmdId.dedup, "", 1, 1, false, 3),
    CmdInfo("number", CmdId.number, "", 1, 1, false, 2),
    CmdInfo("indent", CmdId.indent, "i", 1, 1, false, 2),
    CmdInfo("wrap", CmdId.wrap, "ss", 1, 1, false, 1),
    CmdInfo("count_lines", CmdId.count_lines, "", 1, -1, false, 2),
    CmdInfo("hash", CmdId.hash, "", 1, -1, false, 3),
    CmdInfo("preprocess", CmdId.preprocess, "", 1, 1, true, 6),
];

private immutable(CmdInfo)*[string] cmdByName;

shared static this()
{
    foreach (ref c; cmdTable)
        cmdByName[c.name] = &c;
}

/// Looks up a command by name; null if there is none.
const(CmdInfo)* findCommand(const(char)[] name) @safe
{
    if (auto p = name in cmdByName)
        return *p;
    return null;
}

/// The outcome of executing one command.
struct ExecResult
{
    bool ok;
    KilnError error; /// set when `ok` is false
    string[] outputs; /// content for each declared output, then the depfile
    string[] deps; /// discovered dependencies, sorted (only `preprocess`)
}

private string mapAscii(string s, bool toUpper) pure @safe
{
    char[] r = new char[s.length];
    foreach (i; 0 .. s.length)
    {
        char c = s[i];
        if (toUpper)
        {
            if (c >= 'a' && c <= 'z')
                c = cast(char)(c - 32);
        }
        else if (c >= 'A' && c <= 'Z')
            c = cast(char)(c + 32);
        r[i] = c;
    }
    return (() @trusted => cast(string) r)();
}

private string joinLines(const(string)[] lines) pure @safe
{
    size_t total = 0;
    foreach (l; lines)
        total += l.length + 1;
    char[] r;
    r.reserve(total);
    foreach (l; lines)
    {
        r ~= l;
        r ~= '\n';
    }
    return (() @trusted => cast(string) r)();
}

/// Executes command `info` with arguments `args`.
///
/// `inPaths`/`inContents` are the file inputs in declared order, read at the
/// step's start time. `vfs` is consulted only by `preprocess`, for the files it
/// pulls in. Pure with respect to the workspace: nothing is written.
ExecResult executeCommand(const(CmdInfo)* info, const(Value)[] args, const(string)[] inPaths,
        const(string)[] inContents, Vfs vfs) @safe
{
    ExecResult r;
    r.ok = true;
    final switch (info.id)
    {
    case CmdId.write:
        r.outputs = [args[0].s];
        break;
    case CmdId.copy:
        r.outputs = [inContents[0]];
        break;
    case CmdId.concat:
        {
            char[] b;
            foreach (c; inContents)
                b ~= c;
            r.outputs = [(() @trusted => cast(string) b)()];
            break;
        }
    case CmdId.upper:
        r.outputs = [mapAscii(inContents[0], true)];
        break;
    case CmdId.lower:
        r.outputs = [mapAscii(inContents[0], false)];
        break;
    case CmdId.grep:
        {
            string[] keep;
            foreach (l; splitLines(inContents[0]))
                if (containsBytes(l, args[0].s))
                    keep ~= l;
            r.outputs = [joinLines(keep)];
            break;
        }
    case CmdId.replace:
        r.outputs = [replaceAll(inContents[0], args[0].s, args[1].s)];
        break;
    case CmdId.sort_lines:
        {
            auto ls = splitLines(inContents[0]);
            ls.sort();
            r.outputs = [joinLines(ls)];
            break;
        }
    case CmdId.reverse_lines:
        {
            auto ls = splitLines(inContents[0]);
            foreach (i; 0 .. ls.length / 2)
            {
                auto t = ls[i];
                ls[i] = ls[ls.length - 1 - i];
                ls[ls.length - 1 - i] = t;
            }
            r.outputs = [joinLines(ls)];
            break;
        }
    case CmdId.dedup:
        {
            bool[string] seen;
            string[] keep;
            foreach (l; splitLines(inContents[0]))
                if (l !in seen)
                {
                    seen[l] = true;
                    keep ~= l;
                }
            r.outputs = [joinLines(keep)];
            break;
        }
    case CmdId.number:
        {
            char[] b;
            foreach (i, l; splitLines(inContents[0]))
            {
                b ~= decimal(cast(long) i + 1);
                b ~= ": ";
                b ~= l;
                b ~= '\n';
            }
            r.outputs = [(() @trusted => cast(string) b)()];
            break;
        }
    case CmdId.indent:
        {
            char[] b;
            const n = args[0].num;
            foreach (l; splitLines(inContents[0]))
            {
                foreach (_; 0 .. n)
                    b ~= ' ';
                b ~= l;
                b ~= '\n';
            }
            r.outputs = [(() @trusted => cast(string) b)()];
            break;
        }
    case CmdId.wrap:
        r.outputs = [args[0].s ~ inContents[0] ~ args[1].s];
        break;
    case CmdId.count_lines:
        {
            char[] b;
            long total = 0;
            foreach (i, c; inContents)
            {
                long n = 0;
                foreach (ch; c)
                    if (ch == '\n')
                        ++n;
                if (c.length && c[$ - 1] != '\n')
                    ++n;
                total += n;
                b ~= decimal(n);
                b ~= ' ';
                b ~= inPaths[i];
                b ~= '\n';
            }
            b ~= decimal(total);
            b ~= " total\n";
            r.outputs = [(() @trusted => cast(string) b)()];
            break;
        }
    case CmdId.hash:
        {
            import kiln.hash : fnv1a;

            char[] b;
            foreach (i, c; inContents)
            {
                b ~= toHex16(fnv1a(c));
                b ~= ' ';
                b ~= inPaths[i];
                b ~= '\n';
            }
            r.outputs = [(() @trusted => cast(string) b)()];
            break;
        }
    case CmdId.preprocess:
        preprocess(r, inPaths[0], inContents[0], vfs);
        break;
    }
    return r;
}

private void preprocess(ref ExecResult r, string primary, string primaryContent, Vfs vfs) @safe
{
    char[] outBuf;
    bool[string] found;
    string[] stack = [primary];

    void expand(string p, string content)
    {
        foreach (line; splitLines(content))
        {
            if (line.length > 6 && line[0 .. 6] == "@need ")
            {
                const q = line[6 .. $];
                if (!isWorkspacePath(q))
                    throw new KilnError("E_NEED_PATH", q);
                if (!vfs.exists(q))
                    throw new KilnError("E_NEED_MISSING", q ~ " needed by " ~ p);
                foreach (s; stack)
                    if (s == q)
                        throw new KilnError("E_NEED_CYCLE", q);
                found[q] = true;
                stack ~= q;
                expand(q, vfs.content(q));
                stack.length = stack.length - 1;
            }
            else
            {
                outBuf ~= line;
                outBuf ~= '\n';
            }
        }
    }

    try
    {
        expand(primary, primaryContent);
    }
    catch (KilnError e)
    {
        r.ok = false;
        r.error = e;
        return;
    }
    auto deps = found.keys;
    deps.sort();
    char[] dep = "kiln-deps 1\n".dup;
    foreach (d; deps)
    {
        dep ~= "need ";
        dep ~= d;
        dep ~= '\n';
    }
    r.outputs = [(() @trusted => cast(string) outBuf)(), (() @trusted => cast(string) dep)()];
    r.deps = deps;
}
