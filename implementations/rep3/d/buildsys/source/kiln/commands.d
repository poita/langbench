/// The sixteen built-in commands, their signatures and implementations.
module kiln.commands;

import std.algorithm.sorting : sort;
import kiln.bytes;
import kiln.errors;
import kiln.hash : fnv1a, hex16;
import kiln.paths : isWorkspacePath;
import kiln.vfs : Vfs;

/// A command argument: an int or a str.
struct CmdArg
{
    bool isInt;
    long i;
    string s;

    static CmdArg ofInt(long v) @safe pure nothrow { return CmdArg(true, v, null); }
    static CmdArg ofStr(string v) @safe pure nothrow { return CmdArg(false, 0, v); }
}

/// Static description of a command.
struct CmdSpec
{
    string name;
    string argTypes;   /// one letter per argument: `s` = str, `i` = int
    int minIn;         /// minimum number of file inputs
    int maxIn;         /// maximum number of file inputs (-1 = unbounded)
    bool depfile;      /// whether a depfile is required
    int defaultCost;
}

private immutable CmdSpec[] specs = [
    CmdSpec("write", "s", 0, 0, false, 1),
    CmdSpec("copy", "", 1, 1, false, 1),
    CmdSpec("concat", "", 1, -1, false, 2),
    CmdSpec("upper", "", 1, 1, false, 2),
    CmdSpec("lower", "", 1, 1, false, 2),
    CmdSpec("grep", "s", 1, 1, false, 3),
    CmdSpec("replace", "ss", 1, 1, false, 3),
    CmdSpec("sort_lines", "", 1, 1, false, 4),
    CmdSpec("reverse_lines", "", 1, 1, false, 2),
    CmdSpec("dedup", "", 1, 1, false, 3),
    CmdSpec("number", "", 1, 1, false, 2),
    CmdSpec("indent", "i", 1, 1, false, 2),
    CmdSpec("wrap", "ss", 1, 1, false, 1),
    CmdSpec("count_lines", "", 1, -1, false, 2),
    CmdSpec("hash", "", 1, -1, false, 3),
    CmdSpec("preprocess", "", 1, 1, true, 6),
];

private immutable(CmdSpec)*[string] specIndex;

shared static this()
{
    foreach (ref s; specs)
        specIndex[s.name] = &s;
}

/// Look up a command by name; null when unknown.
immutable(CmdSpec)* lookupCommand(string name)
{
    if (auto p = name in specIndex)
        return *p;
    return null;
}

/// All command specs, in documentation order.
immutable(CmdSpec)[] allCommands()
{
    return specs;
}

/// Canonical rendering of a command: `name(arg, arg)`.
string renderCommand(string name, const(CmdArg)[] args)
{
    Buf b;
    b.put(name);
    b.putc('(');
    foreach (i, ref a; args)
    {
        if (i > 0)
            b.put(", ");
        if (a.isInt)
            b.putInt(a.i);
        else
            putEscaped(b, a.s);
    }
    b.putc(')');
    return b.take();
}

private void putEscaped(ref Buf b, string s)
{
    static immutable hexd = "0123456789abcdef";
    b.putc('"');
    foreach (c; s)
    {
        switch (c)
        {
        case '\\': b.put("\\\\"); break;
        case '"': b.put("\\\""); break;
        case '\n': b.put("\\n"); break;
        case '\t': b.put("\\t"); break;
        case '\r': b.put("\\r"); break;
        default:
            if (cast(ubyte) c < 0x20 || c == 0x7f)
            {
                b.put("\\x");
                b.putc(hexd[(cast(ubyte) c) >> 4]);
                b.putc(hexd[(cast(ubyte) c) & 15]);
            }
            else
                b.putc(c);
        }
    }
    b.putc('"');
}

/// A file a command read, with the hash of the content it saw.
struct ReadFile
{
    string path;
    string data;
    ulong hash;
}

/// What running a command produced.
struct CmdResult
{
    KilnError error;           /// non-null: an execution error
    string output;             /// content of the primary output
    string depfileContent;     /// content of the depfile (preprocess only)
    ReadFile[] discovered;     /// files read beyond the declared inputs, sorted by path
}

/// Run a command over already-captured inputs. `vfs` is only consulted by
/// `preprocess`, for the files it is told to `@need`.
CmdResult runCommand(string name, const(CmdArg)[] args, ReadFile[] ins, Vfs vfs)
{
    CmdResult r;
    switch (name)
    {
    case "write":
        r.output = args[0].s;
        break;
    case "copy":
        r.output = ins[0].data;
        break;
    case "concat":
    {
        Buf b;
        foreach (ref f; ins)
            b.put(f.data);
        r.output = b.take();
        break;
    }
    case "upper":
        r.output = mapCase(ins[0].data, 'a', 'z', -32);
        break;
    case "lower":
        r.output = mapCase(ins[0].data, 'A', 'Z', 32);
        break;
    case "grep":
    {
        Buf b;
        foreach (line; splitLines(ins[0].data))
            if (findBytes(line, args[0].s) != size_t.max)
            {
                b.put(line);
                b.putc('\n');
            }
        r.output = b.take();
        break;
    }
    case "replace":
        r.output = replaceAll(ins[0].data, args[0].s, args[1].s);
        break;
    case "sort_lines":
    {
        auto lines = splitLines(ins[0].data);
        lines.sort();
        r.output = joinLines(lines);
        break;
    }
    case "reverse_lines":
    {
        auto lines = splitLines(ins[0].data);
        Buf b;
        foreach_reverse (line; lines)
        {
            b.put(line);
            b.putc('\n');
        }
        r.output = b.take();
        break;
    }
    case "dedup":
    {
        bool[string] seen;
        Buf b;
        foreach (line; splitLines(ins[0].data))
        {
            if (line in seen)
                continue;
            seen[line] = true;
            b.put(line);
            b.putc('\n');
        }
        r.output = b.take();
        break;
    }
    case "number":
    {
        Buf b;
        long n = 0;
        foreach (line; splitLines(ins[0].data))
        {
            b.putInt(++n);
            b.put(": ");
            b.put(line);
            b.putc('\n');
        }
        r.output = b.take();
        break;
    }
    case "indent":
    {
        Buf b;
        foreach (line; splitLines(ins[0].data))
        {
            foreach (_; 0 .. cast(size_t) args[0].i)
                b.putc(' ');
            b.put(line);
            b.putc('\n');
        }
        r.output = b.take();
        break;
    }
    case "wrap":
    {
        Buf b;
        b.put(args[0].s);
        b.put(ins[0].data);
        b.put(args[1].s);
        r.output = b.take();
        break;
    }
    case "count_lines":
    {
        Buf b;
        size_t total = 0;
        foreach (ref f; ins)
        {
            immutable n = countLines(f.data);
            total += n;
            b.putInt(n);
            b.putc(' ');
            b.put(f.path);
            b.putc('\n');
        }
        b.putInt(total);
        b.put(" total\n");
        r.output = b.take();
        break;
    }
    case "hash":
    {
        Buf b;
        foreach (ref f; ins)
        {
            b.put(hex16(f.hash));
            b.putc(' ');
            b.put(f.path);
            b.putc('\n');
        }
        r.output = b.take();
        break;
    }
    case "preprocess":
        runPreprocess(ins[0], vfs, r);
        break;
    default:
        assert(0, "unknown command " ~ name);
    }
    return r;
}

private string mapCase(string s, char lo, char hi, int delta)
{
    auto r = new char[s.length];
    foreach (i, c; s)
        r[i] = (c >= lo && c <= hi) ? cast(char)(c + delta) : c;
    return cast(string) r;
}

private string joinLines(const(string)[] lines)
{
    Buf b;
    foreach (l; lines)
    {
        b.put(l);
        b.putc('\n');
    }
    return b.take();
}

// ------------------------------------------------------------ preprocess

private struct Expander
{
    Vfs vfs;
    Buf* output;
    string[] stack;
    ReadFile[string] found;

    void expand(string path, string content)
    {
        stack ~= path;
        foreach (line; splitLines(content))
        {
            if (line.length > 6 && startsWithBytes(line, "@need "))
            {
                auto q = line[6 .. $];
                if (!isWorkspacePath(q))
                    throw new KilnError("E_NEED_PATH", q);
                if (!vfs.exists(q))
                    throw new KilnError("E_NEED_MISSING", q ~ " needed by " ~ path);
                foreach (s; stack)
                    if (s == q)
                        throw new KilnError("E_NEED_CYCLE", q);
                if (q !in found)
                    found[q] = ReadFile(q, vfs.read(q), vfs.hashOf(q));
                expand(q, vfs.read(q));
            }
            else
            {
                output.put(line);
                output.putc('\n');
            }
        }
        stack.length = stack.length - 1;
    }
}

private void runPreprocess(ref ReadFile input, Vfs vfs, ref CmdResult r)
{
    Buf out_;
    Expander ex;
    ex.vfs = vfs;
    ex.output = &out_;
    try
        ex.expand(input.path, input.data);
    catch (KilnError e)
    {
        r.error = e;
        return;
    }
    r.output = out_.take();
    auto keys = ex.found.keys;
    keys.sort();
    Buf d;
    d.put("kiln-deps 1\n");
    foreach (k; keys)
    {
        d.put("need ");
        d.put(k);
        d.putc('\n');
        r.discovered ~= ex.found[k];
    }
    r.depfileContent = d.take();
}
