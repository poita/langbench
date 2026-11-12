/**
 * The sixteen built-in commands: their signatures, the canonical command
 * string, and their implementations over the virtual file system.
 */
module kiln.commands;

import kiln.bytes;
import kiln.errors;
import kiln.hash : fnv1a, hex16;
import kiln.model : Step;
import kiln.value;
import kiln.workspace : Workspace, isWorkspacePath;

/// Argument kinds a command can take.
enum ArgKind : ubyte
{
    str,
    integer,
}

/// A command's static description.
struct CommandSpec
{
    string name;
    immutable(ArgKind)[] args;
    size_t minInputs;
    /// Maximum number of file inputs; `size_t.max` for "or more".
    size_t maxInputs;
    bool usesDepfile;
    long defaultCost;
}

private enum S = ArgKind.str;
private enum I = ArgKind.integer;
private enum many = size_t.max;

private immutable CommandSpec[] specs = [
    CommandSpec("write", [S], 0, 0, false, 1),
    CommandSpec("copy", [], 1, 1, false, 1),
    CommandSpec("concat", [], 1, many, false, 2),
    CommandSpec("upper", [], 1, 1, false, 2),
    CommandSpec("lower", [], 1, 1, false, 2),
    CommandSpec("grep", [S], 1, 1, false, 3),
    CommandSpec("replace", [S, S], 1, 1, false, 3),
    CommandSpec("sort_lines", [], 1, 1, false, 4),
    CommandSpec("reverse_lines", [], 1, 1, false, 2),
    CommandSpec("dedup", [], 1, 1, false, 3),
    CommandSpec("number", [], 1, 1, false, 2),
    CommandSpec("indent", [I], 1, 1, false, 2),
    CommandSpec("wrap", [S, S], 1, 1, false, 1),
    CommandSpec("count_lines", [], 1, many, false, 2),
    CommandSpec("hash", [], 1, many, false, 3),
    CommandSpec("preprocess", [], 1, 1, true, 6),
];

/// The spec of the command called `name`, or null.
const(CommandSpec)* lookupCommand(const(char)[] name) @safe pure nothrow @nogc
{
    foreach (i; 0 .. specs.length)
        if (specs[i].name == name)
            return &specs[i];
    return null;
}

/// Renders a string argument with the canonical escapes.
private void appendQuoted(ref char[] buf, string s) @safe pure nothrow
{
    static immutable hexd = "0123456789abcdef";
    buf ~= '"';
    foreach (c; s)
    {
        switch (c)
        {
        case '\\':
            buf ~= `\\`;
            break;
        case '"':
            buf ~= `\"`;
            break;
        case '\n':
            buf ~= `\n`;
            break;
        case '\t':
            buf ~= `\t`;
            break;
        case '\r':
            buf ~= `\r`;
            break;
        default:
            if (c < 0x20 || c == 0x7f)
            {
                buf ~= `\x`;
                buf ~= hexd[c >> 4];
                buf ~= hexd[c & 15];
            }
            else
                buf ~= c;
        }
    }
    buf ~= '"';
}

/// The canonical command string: `name(arg, arg, ...)`.
string renderCommand(string name, const(Value)[] args) @safe pure nothrow
{
    char[] buf;
    buf ~= name;
    buf ~= '(';
    foreach (k, ref a; args)
    {
        if (k)
            buf ~= ", ";
        if (a.type == ValueType.integer)
            buf ~= decimal(a.i);
        else
            appendQuoted(buf, a.s);
    }
    buf ~= ')';
    return (() @trusted => cast(string) buf)();
}

/// The `<lo>-<hi>` text used by `E_CMD_SHAPE` for the input count.
string inputRange(const ref CommandSpec s) @safe pure nothrow
{
    return decimal(s.minInputs) ~ "-" ~ (s.maxInputs == many ? "N" : decimal(s.maxInputs));
}

/// What a successful command run produced.
struct CommandResult
{
    /// Contents for each entry of the step's full output list, in order.
    string[] outputs;
    /// Paths discovered while running (only `preprocess`), sorted.
    string[] discovered;
}

/**
 * Runs `step`'s command against `ws` and returns what it wants written.
 * Throws `KilnError` for execution errors (only `preprocess` has any).
 */
CommandResult runCommand(const Step step, Workspace ws) @safe
{
    CommandResult res;
    auto a = step.cmdArgs;
    auto ins = step.fileInputs;
    switch (step.cmdName)
    {
    case "write":
        res.outputs = [a[0].s];
        break;
    case "copy":
        res.outputs = [ws.read(ins[0])];
        break;
    case "concat":
        {
            char[] buf;
            foreach (p; ins)
                buf ~= ws.read(p);
            res.outputs = [(() @trusted => cast(string) buf)()];
            break;
        }
    case "upper":
        res.outputs = [toUpperAscii(ws.read(ins[0]))];
        break;
    case "lower":
        res.outputs = [toLowerAscii(ws.read(ins[0]))];
        break;
    case "grep":
        {
            string[] keep;
            foreach (l; splitLines(ws.read(ins[0])))
                if (contains(l, a[0].s))
                    keep ~= l;
            res.outputs = [joinLines(keep)];
            break;
        }
    case "replace":
        res.outputs = [replaceAll(ws.read(ins[0]), a[0].s, a[1].s)];
        break;
    case "sort_lines":
        {
            import std.algorithm.sorting : sort;

            auto ls = splitLines(ws.read(ins[0]));
            ls.sort!((x, y) => cmpBytes(x, y) < 0);
            res.outputs = [joinLines(ls)];
            break;
        }
    case "reverse_lines":
        {
            import std.algorithm.mutation : reverse;

            auto ls = splitLines(ws.read(ins[0]));
            ls.reverse();
            res.outputs = [joinLines(ls)];
            break;
        }
    case "dedup":
        {
            bool[string] seen;
            string[] keep;
            foreach (l; splitLines(ws.read(ins[0])))
            {
                if (l in seen)
                    continue;
                seen[l] = true;
                keep ~= l;
            }
            res.outputs = [joinLines(keep)];
            break;
        }
    case "number":
        {
            char[] buf;
            foreach (k, l; splitLines(ws.read(ins[0])))
            {
                buf ~= decimal(cast(long) k + 1);
                buf ~= ": ";
                buf ~= l;
                buf ~= '\n';
            }
            res.outputs = [(() @trusted => cast(string) buf)()];
            break;
        }
    case "indent":
        {
            char[] buf;
            foreach (l; splitLines(ws.read(ins[0])))
            {
                foreach (_; 0 .. a[0].i)
                    buf ~= ' ';
                buf ~= l;
                buf ~= '\n';
            }
            res.outputs = [(() @trusted => cast(string) buf)()];
            break;
        }
    case "wrap":
        res.outputs = [a[0].s ~ ws.read(ins[0]) ~ a[1].s];
        break;
    case "count_lines":
        {
            char[] buf;
            long total = 0;
            foreach (p; ins)
            {
                immutable n = cast(long) countLines(ws.read(p));
                total += n;
                buf ~= decimal(n);
                buf ~= ' ';
                buf ~= p;
                buf ~= '\n';
            }
            buf ~= decimal(total);
            buf ~= " total\n";
            res.outputs = [(() @trusted => cast(string) buf)()];
            break;
        }
    case "hash":
        {
            char[] buf;
            foreach (p; ins)
            {
                buf ~= hex16(fnv1a(ws.read(p)));
                buf ~= ' ';
                buf ~= p;
                buf ~= '\n';
            }
            res.outputs = [(() @trusted => cast(string) buf)()];
            break;
        }
    case "preprocess":
        {
            auto pp = new Preprocessor(ws);
            pp.expand(ins[0]);
            res.outputs = [(() @trusted => cast(string) pp.output)()];
            res.discovered = pp.discoveredSorted();
            char[] dep;
            dep ~= "kiln-deps 1\n";
            foreach (d; res.discovered)
            {
                dep ~= "need ";
                dep ~= d;
                dep ~= '\n';
            }
            res.outputs ~= (() @trusted => cast(string) dep)();
            break;
        }
    default:
        assert(0, "unknown command " ~ step.cmdName);
    }
    return res;
}

/// Expands `@need` directives depth-first, recording what it read.
private final class Preprocessor
{
    Workspace ws;
    char[] output;
    bool[string] onStack;
    bool[string] discovered;

    this(Workspace ws) @safe pure nothrow @nogc
    {
        this.ws = ws;
    }

    void expand(string p) @safe
    {
        onStack[p] = true;
        foreach (line; splitLines(ws.read(p)))
        {
            if (line.length > 6 && startsWith(line, "@need "))
            {
                auto q = line[6 .. $];
                if (!isWorkspacePath(q))
                    fail("E_NEED_PATH", q);
                if (!ws.exists(q))
                    fail("E_NEED_MISSING", q ~ " needed by " ~ p);
                if (q in onStack)
                    fail("E_NEED_CYCLE", q);
                discovered[q] = true;
                expand(q);
            }
            else
            {
                output ~= line;
                output ~= '\n';
            }
        }
        onStack.remove(p);
    }

    string[] discoveredSorted() @safe
    {
        import kiln.workspace : sortPaths;

        auto r = discovered.keys;
        sortPaths(r);
        return r;
    }
}

@safe unittest
{
    assert(lookupCommand("grep") !is null && lookupCommand("nope") is null);
    assert(renderCommand("write", [Value.ofStr("a\n\"b\"\\\x01\x7f\xc3\xbc")])
            == `write("a\n\"b\"\\\x01\x7fü")`);
    assert(renderCommand("indent", [Value.ofInt(4)]) == "indent(4)");
    assert(renderCommand("concat", []) == "concat()");
}

version (unittest)
{
    private Step mk(string cmd, Value[] args, string[] ins) @safe
    {
        auto s = new Step;
        s.cmdName = cmd;
        s.cmdArgs = args;
        s.fileInputs = ins;
        return s;
    }
}

@safe unittest
{
    auto ws = new Workspace;
    ws.write("a", "b\na\nb\n");
    assert(runCommand(mk("sort_lines", [], ["a"]), ws).outputs == ["a\nb\nb\n"]);
    assert(runCommand(mk("dedup", [], ["a"]), ws).outputs == ["b\na\n"]);
    assert(runCommand(mk("number", [], ["a"]), ws).outputs == ["1: b\n2: a\n3: b\n"]);
    assert(runCommand(mk("grep", [Value.ofStr("a")], ["a"]), ws).outputs == ["a\n"]);
    assert(runCommand(mk("count_lines", [], ["a"]), ws).outputs == ["3 a\n3 total\n"]);
    assert(runCommand(mk("wrap", [Value.ofStr("<"), Value.ofStr(">")], ["a"]), ws).outputs == ["<b\na\nb\n>"]);
    ws.write("m", "t\n@need p\ne\n");
    ws.write("p", "P\n@need d\n");
    ws.write("d", "D\n");
    auto r = runCommand(mk("preprocess", [], ["m"]), ws);
    assert(r.outputs[0] == "t\nP\nD\ne\n" && r.outputs[1] == "kiln-deps 1\nneed d\nneed p\n");
    ws.write("d", "@need m\n");
    import std.exception : collectException;

    auto e = collectException!KilnError(runCommand(mk("preprocess", [], ["m"]), ws));
    assert(e && e.kind == "E_NEED_CYCLE" && e.detail == "m");
}
