/**
 * The sixteen built-in commands and their execution against the virtual file system.
 */
module kiln.commands;

import kiln.errors;
import kiln.hash : toHex16;
import kiln.step;
import kiln.text;
import kiln.value;
import kiln.vfs;

/// Static description of a command.
struct CommandSpec
{
    ///
    string name;
    /// Argument types: `str` or `int`.
    Value.Type[] args;
    /// Minimum and maximum number of file inputs (`maxInputs == size_t.max` means unbounded).
    size_t minInputs, maxInputs;
    /// Whether the command requires (and only allows) a `depfile`.
    bool usesDepfile;
    /// Cost when the step has no `cost` field.
    long defaultCost;
}

private __gshared CommandSpec[string] specs;

/// Looks up a command by name; null if unknown.
const(CommandSpec)* findCommand(const(char)[] name)
{
    auto p = name in specs;
    return p ? p : null;
}

/// Names of all commands.
string[] commandNames()
{
    return specs.keys;
}

shared static this()
{
    alias T = Value.Type;
    enum N = size_t.max;
    void add(string name, Value.Type[] args, size_t lo, size_t hi, long cost, bool dep = false)
    {
        specs[name] = CommandSpec(name, args, lo, hi, dep, cost);
    }

    add("write", [T.str], 0, 0, 1);
    add("copy", [], 1, 1, 1);
    add("concat", [], 1, N, 2);
    add("upper", [], 1, 1, 2);
    add("lower", [], 1, 1, 2);
    add("grep", [T.str], 1, 1, 3);
    add("replace", [T.str, T.str], 1, 1, 3);
    add("sort_lines", [], 1, 1, 4);
    add("reverse_lines", [], 1, 1, 2);
    add("dedup", [], 1, 1, 3);
    add("number", [], 1, 1, 2);
    add("indent", [T.integer], 1, 1, 2);
    add("wrap", [T.str, T.str], 1, 1, 1);
    add("count_lines", [], 1, N, 2);
    add("hash", [], 1, N, 3);
    add("preprocess", [], 1, 1, 6, true);
}

/// The result of running a command: everything it reads and everything it will write.
final class Execution
{
    /// The execution error, or null on success.
    KilnError error;
    /// Contents for `Step.fullOuts`, in the same order.
    string[] outputs;
    /// Hashes of the file inputs as read, in `fileInputs` order.
    ulong[] inputHashes;
    /// Discovered dependency paths (sorted) and the hashes of the content read.
    string[] deps;
    ///
    ulong[] depHashes;
}

/// Runs `step`'s command, reading from `fs` (nothing is written to it).
Execution executeCommand(Step step, Vfs fs)
{
    auto ex = new Execution;
    string[] inputs;
    foreach (p; step.fileInputs)
    {
        auto f = fs.get(p);
        inputs ~= f is null ? "" : f.content;
        ex.inputHashes ~= f is null ? (new FileEntry("")).hash : f.hash;
    }
    string result;
    string depfile;
    try
    {
        result = runCommandBody(step, fs, inputs, ex, depfile);
    }
    catch (KilnError e)
    {
        ex.error = e;
        return ex;
    }
    ex.outputs = [result];
    if (step.hasDepfile)
        ex.outputs ~= depfile;
    return ex;
}

private string linesOut(const(string)[] lines) @safe pure nothrow
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

private string runCommandBody(Step step, Vfs fs, string[] inputs, Execution ex, out string depfile)
{
    import std.algorithm.sorting : sort;
    import std.conv : to;

    const args = step.cmdArgs;
    switch (step.cmdName)
    {
    case "write":
        return args[0].text;
    case "copy":
        return inputs[0];
    case "concat":
    {
        string r;
        foreach (c; inputs)
            r ~= c;
        return r;
    }
    case "upper":
    case "lower":
    {
        const up = step.cmdName == "upper";
        char[] r = inputs[0].dup;
        foreach (ref c; r)
        {
            if (up && c >= 'a' && c <= 'z')
                c -= 32;
            else if (!up && c >= 'A' && c <= 'Z')
                c += 32;
        }
        return (() @trusted => cast(string) r)();
    }
    case "grep":
    {
        string[] keep;
        foreach (l; splitLines(inputs[0]))
            if (containsBytes(l, args[0].text))
                keep ~= l;
        return linesOut(keep);
    }
    case "replace":
        return replaceAllBytes(inputs[0], args[0].text, args[1].text);
    case "sort_lines":
    {
        auto lines = splitLines(inputs[0]);
        lines.sort!((a, b) => cmpBytes(a, b) < 0);
        return linesOut(lines);
    }
    case "reverse_lines":
    {
        auto lines = splitLines(inputs[0]);
        foreach (i; 0 .. lines.length / 2)
        {
            const t = lines[i];
            lines[i] = lines[$ - 1 - i];
            lines[$ - 1 - i] = t;
        }
        return linesOut(lines);
    }
    case "dedup":
    {
        bool[string] seen;
        string[] keep;
        foreach (l; splitLines(inputs[0]))
        {
            if (l !in seen)
            {
                seen[l] = true;
                keep ~= l;
            }
        }
        return linesOut(keep);
    }
    case "number":
    {
        string[] out_;
        foreach (i, l; splitLines(inputs[0]))
            out_ ~= (i + 1).to!string ~ ": " ~ l;
        return linesOut(out_);
    }
    case "indent":
    {
        const pad = replicateSpaces(cast(size_t) args[0].num);
        string[] out_;
        foreach (l; splitLines(inputs[0]))
            out_ ~= pad ~ l;
        return linesOut(out_);
    }
    case "wrap":
        return args[0].text ~ inputs[0] ~ args[1].text;
    case "count_lines":
    {
        string[] out_;
        size_t total = 0;
        foreach (i, c; inputs)
        {
            const n = countLines(c);
            total += n;
            out_ ~= n.to!string ~ " " ~ step.fileInputs[i];
        }
        out_ ~= total.to!string ~ " total";
        return linesOut(out_);
    }
    case "hash":
    {
        string[] out_;
        foreach (i, h; ex.inputHashes)
            out_ ~= toHex16(h) ~ " " ~ step.fileInputs[i];
        return linesOut(out_);
    }
    case "preprocess":
    {
        auto pp = new Preprocessor(fs);
        const result = pp.run(step.fileInputs[0], inputs[0]);
        auto deps = pp.discovered.keys;
        deps.sort!((a, b) => cmpBytes(a, b) < 0);
        string d = "kiln-deps 1\n";
        foreach (p; deps)
        {
            d ~= "need " ~ p ~ "\n";
            ex.deps ~= p;
            ex.depHashes ~= fs.get(p).hash;
        }
        depfile = d;
        return result;
    }
    default:
        assert(false, "unknown command " ~ step.cmdName);
    }
}

private string replicateSpaces(size_t n) @safe pure nothrow
{
    auto r = new char[n];
    r[] = ' ';
    return (() @trusted => cast(string) r)();
}

/// `@need` expansion for the `preprocess` command.
private final class Preprocessor
{
    Vfs fs;
    bool[string] discovered;
    private bool[string] onStack;
    private char[] output;

    this(Vfs fs) { this.fs = fs; }

    string run(string path, string content)
    {
        expand(path, content);
        return (() @trusted => cast(string) output)();
    }

    private void expand(string path, string content)
    {
        onStack[path] = true;
        foreach (line; splitLines(content))
        {
            if (startsWithBytes(line, "@need ") && line.length > 6)
            {
                const q = line[6 .. $];
                if (!isWorkspacePath(q))
                    throw new KilnError("E_NEED_PATH", q);
                auto f = fs.get(q);
                if (f is null)
                    throw new KilnError("E_NEED_MISSING", q ~ " needed by " ~ path);
                if (q in onStack)
                    throw new KilnError("E_NEED_CYCLE", q);
                discovered[q] = true;
                expand(q, f.content);
            }
            else
            {
                output ~= line;
                output ~= '\n';
            }
        }
        onStack.remove(path);
    }
}

version (unittest)
{
    private Step mk(string cmd, string[] ins, Value[] args = [], bool dep = false)
    {
        auto s = new Step;
        s.cmdName = cmd;
        s.cmdArgs = args;
        s.fileInputs = ins;
        s.outs = ["out/o"];
        s.fullOuts = dep ? ["out/o", "out/o.d"] : ["out/o"];
        s.hasDepfile = dep;
        return s;
    }

    private string run(string cmd, string input, Value[] args = [])
    {
        auto fs = new Vfs;
        fs.write("in", input);
        auto ex = executeCommand(mk(cmd, ["in"], args), fs);
        assert(ex.error is null);
        return ex.outputs[0];
    }
}

unittest
{
    assert(commandNames().length == 16);
    assert(run("upper", "aé1\n") == "Aé1\n");
    assert(run("lower", "ABC") == "abc");
    assert(run("grep", "ab\ncd\nxab\n", [Value.ofStr("ab")]) == "ab\nxab\n");
    assert(run("grep", "a\nb", [Value.ofStr("")]) == "a\nb\n");
    assert(run("replace", "aaa", [Value.ofStr("aa"), Value.ofStr("b")]) == "ba");
    assert(run("sort_lines", "b\na\nc") == "a\nb\nc\n");
    assert(run("reverse_lines", "a\nb\nc\n") == "c\nb\na\n");
    assert(run("dedup", "a\nb\na\n") == "a\nb\n");
    assert(run("number", "a\nb\nc\n") == "1: a\n2: b\n3: c\n");
    assert(run("indent", "a\n\n", [Value.ofInt(2)]) == "  a\n  \n");
    assert(run("wrap", "x", [Value.ofStr("<"), Value.ofStr(">")]) == "<x>");
    assert(run("copy", "") == "");
}

unittest
{
    auto fs = new Vfs;
    fs.write("src/a.txt", "x\ny\n");
    fs.write("src/b.txt", "");
    auto ex = executeCommand(mk("count_lines", ["src/a.txt", "src/b.txt"]), fs);
    assert(ex.outputs[0] == "2 src/a.txt\n0 src/b.txt\n2 total\n");
    ex = executeCommand(mk("hash", ["src/b.txt", "src/b.txt"]), fs);
    assert(ex.outputs[0] == "cbf29ce484222325 src/b.txt\ncbf29ce484222325 src/b.txt\n");
}

unittest
{
    auto fs = new Vfs;
    fs.write("src/main.txt", "title\n@need src/part.txt\nend\n");
    fs.write("src/part.txt", "PART-A\n@need src/deep.txt\n");
    fs.write("src/deep.txt", "DEEP\n");
    auto ex = executeCommand(mk("preprocess", ["src/main.txt"], [], true), fs);
    assert(ex.error is null);
    assert(ex.outputs[0] == "title\nPART-A\nDEEP\nend\n");
    assert(ex.outputs[1] == "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n");
    assert(ex.deps == ["src/deep.txt", "src/part.txt"]);

    fs.write("src/main.txt", "@need src/gone.txt\n");
    ex = executeCommand(mk("preprocess", ["src/main.txt"], [], true), fs);
    assert(ex.error !is null && ex.error.msg == "E_NEED_MISSING src/gone.txt needed by src/main.txt");
    fs.write("src/main.txt", "@need a b\n");
    ex = executeCommand(mk("preprocess", ["src/main.txt"], [], true), fs);
    assert(ex.error.msg == "E_NEED_PATH a b");
    fs.write("src/main.txt", "@need src/main.txt\n");
    ex = executeCommand(mk("preprocess", ["src/main.txt"], [], true), fs);
    assert(ex.error.msg == "E_NEED_CYCLE src/main.txt");
}
