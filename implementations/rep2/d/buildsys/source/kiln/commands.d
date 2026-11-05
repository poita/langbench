/**
 * Execution of the sixteen built-in commands against captured input contents.
 */
module kiln.commands;

import kiln.errors;
import kiln.hash;
import kiln.paths;
import kiln.step;
import kiln.text;
import kiln.value;
import kiln.vfs;

import std.algorithm : sort;
import std.array : appender;
import std.conv : to;

/// What a command produced.
struct CommandResult
{
    /// One content per entry of the step's full output list.
    string[] outputs;
    /// Discovered dependency paths (sorted) and the hashes of what was read.
    string[] depPaths;
    ulong[] depHashes;
}

/**
 * Runs the step's command.
 *
 * Params:
 *   step = the step
 *   inputs = contents of `step.fileInputs`, captured at start time
 *   vfs = the workspace, read by `preprocess` for needed files
 *
 * Throws: `KilnError` for the `preprocess` execution errors.
 */
CommandResult runCommand(const Step step, const(string)[] inputs, Vfs vfs)
{
    CommandResult r;
    auto a = step.args;
    string one;
    final switch (step.cmd)
    {
    case Cmd.write:
        one = a[0].s;
        break;
    case Cmd.copy:
        one = inputs[0];
        break;
    case Cmd.concat:
    {
        auto app = appender!(char[]);
        foreach (c; inputs)
            app.put(c);
        one = toImmutable(app.data);
        break;
    }
    case Cmd.upper:
    {
        auto b = inputs[0].dup;
        foreach (ref c; b)
            if (c >= 'a' && c <= 'z')
                c -= 32;
        one = toImmutable(b);
        break;
    }
    case Cmd.lower:
    {
        auto b = inputs[0].dup;
        foreach (ref c; b)
            if (c >= 'A' && c <= 'Z')
                c += 32;
        one = toImmutable(b);
        break;
    }
    case Cmd.grep:
    {
        string[] keep;
        foreach (l; splitLines(inputs[0]))
            if (containsBytes(l, a[0].s))
                keep ~= l;
        one = joinLines(keep);
        break;
    }
    case Cmd.replace:
        one = replaceAll(inputs[0], a[0].s, a[1].s);
        break;
    case Cmd.sort_lines:
    {
        auto ls = splitLines(inputs[0]);
        ls.sort();
        one = joinLines(ls);
        break;
    }
    case Cmd.reverse_lines:
    {
        auto ls = splitLines(inputs[0]);
        foreach (i; 0 .. ls.length / 2)
        {
            auto tmp = ls[i];
            ls[i] = ls[$ - 1 - i];
            ls[$ - 1 - i] = tmp;
        }
        one = joinLines(ls);
        break;
    }
    case Cmd.dedup:
    {
        string[] keep;
        bool[string] seen;
        foreach (l; splitLines(inputs[0]))
            if (l !in seen)
            {
                seen[l] = true;
                keep ~= l;
            }
        one = joinLines(keep);
        break;
    }
    case Cmd.number:
    {
        auto app = appender!(char[]);
        foreach (i, l; splitLines(inputs[0]))
        {
            app.put((i + 1).to!string);
            app.put(": ");
            app.put(l);
            app.put('\n');
        }
        one = toImmutable(app.data);
        break;
    }
    case Cmd.indent:
    {
        auto app = appender!(char[]);
        immutable n = cast(size_t) a[0].i;
        foreach (l; splitLines(inputs[0]))
        {
            foreach (_; 0 .. n)
                app.put(' ');
            app.put(l);
            app.put('\n');
        }
        one = toImmutable(app.data);
        break;
    }
    case Cmd.wrap:
        one = a[0].s ~ inputs[0] ~ a[1].s;
        break;
    case Cmd.count_lines:
    {
        auto app = appender!(char[]);
        size_t total = 0;
        foreach (i, c; inputs)
        {
            immutable n = countLines(c);
            total += n;
            app.put(n.to!string);
            app.put(' ');
            app.put(step.fileInputs[i]);
            app.put('\n');
        }
        app.put(total.to!string);
        app.put(" total\n");
        one = toImmutable(app.data);
        break;
    }
    case Cmd.hash:
    {
        auto app = appender!(char[]);
        foreach (i, c; inputs)
        {
            app.put(toHex16(fnv1a(c)));
            app.put(' ');
            app.put(step.fileInputs[i]);
            app.put('\n');
        }
        one = toImmutable(app.data);
        break;
    }
    case Cmd.preprocess:
    {
        auto pp = Preprocessor(vfs);
        pp.stack ~= step.fileInputs[0];
        pp.expand(step.fileInputs[0], inputs[0]);
        one = toImmutable(pp.output.data);
        auto found = pp.discovered.keys;
        found.sort();
        auto dep = appender!(char[]);
        dep.put("kiln-deps 1\n");
        foreach (p; found)
        {
            dep.put("need ");
            dep.put(p);
            dep.put('\n');
            r.depPaths ~= p;
            r.depHashes ~= vfs.hashOf(p);
        }
        r.outputs = [one, toImmutable(dep.data)];
        return r;
    }
    }
    r.outputs = [one];
    return r;
}

private struct Preprocessor
{
    Vfs vfs;
    string[] stack;
    bool[string] discovered;
    typeof(appender!(char[])()) output;

    this(Vfs v)
    {
        vfs = v;
        output = appender!(char[]);
    }

    void expand(string path, string content)
    {
        foreach (line; splitLines(content))
        {
            if (line.length > 6 && line[0 .. 6] == "@need ")
            {
                string q = line[6 .. $];
                if (!isWorkspacePath(q))
                    throw new KilnError("E_NEED_PATH", q);
                if (!vfs.exists(q))
                    throw new KilnError("E_NEED_MISSING", q ~ " needed by " ~ path);
                foreach (s; stack)
                    if (s == q)
                        throw new KilnError("E_NEED_CYCLE", q);
                discovered[q] = true;
                stack ~= q;
                expand(q, vfs.read(q));
                stack.length = stack.length - 1;
            }
            else
            {
                output.put(line);
                output.put('\n');
            }
        }
    }
}
