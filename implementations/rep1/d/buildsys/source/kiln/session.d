/**
 * Session scripts: parsing `session.txt`, running the scripted builds and
 * workspace mutations, and writing the session log.
 */
module kiln.session;

import std.array : Appender, appender;
import std.conv : to;

import kiln.errors;
import kiln.scheduler;
import kiln.text;
import kiln.vfs;

/// One step of a session script.
struct SessionStep
{
    /// Kinds of session steps.
    enum Kind : ubyte { build, create, edit, delete_, touch, clean }

    ///
    Kind kind;
    /// `build`: the targets as written.
    string[] targets;
    /// `build`: the worker count.
    int workers = 1;
    /// `create`, `edit`, `delete`, `touch`: the path.
    string path;
    /// `create`, `edit`: the new content.
    string content;
}

/// Parses `session.txt` text.
SessionStep[] parseSession(string text)
{
    SessionStep[] steps;
    auto lines = splitLinesKeepEmpty(text);
    size_t i = 0;
    while (i < lines.length)
    {
        const line = lines[i++];
        const t = stripBlanks(line);
        if (t.length == 0 || t[0] == '#')
            continue;
        auto words = splitWords(t);
        SessionStep s;
        switch (words[0])
        {
        case "build":
            s.kind = SessionStep.Kind.build;
            auto ws = words[1 .. $];
            if (words.length >= 3 && words[$ - 2] == "-j")
            {
                s.workers = words[$ - 1].to!int;
                ws = words[1 .. $ - 2];
            }
            s.targets = ws;
            break;
        case "create":
        case "edit":
            s.kind = words[0] == "create" ? SessionStep.Kind.create : SessionStep.Kind.edit;
            s.path = words[1];
            string content;
            while (i < lines.length && lines[i] != "---")
                content ~= lines[i++] ~ "\n";
            ++i; // the terminator
            s.content = content;
            break;
        case "delete":
            s.kind = SessionStep.Kind.delete_;
            s.path = words[1];
            break;
        case "touch":
            s.kind = SessionStep.Kind.touch;
            s.path = words[1];
            break;
        case "clean":
            s.kind = SessionStep.Kind.clean;
            break;
        default:
            throw new Exception("bad session step: " ~ t);
        }
        steps ~= s;
    }
    return steps;
}

private string[] splitLinesKeepEmpty(string text)
{
    string[] r;
    size_t start = 0;
    foreach (i, char c; text)
        if (c == '\n')
        {
            r ~= text[start .. i];
            start = i + 1;
        }
    if (start < text.length)
        r ~= text[start .. $];
    return r;
}

private string stripBlanks(string s)
{
    size_t lo = 0, hi = s.length;
    while (lo < hi && (s[lo] == ' ' || s[lo] == '\t'))
        ++lo;
    while (hi > lo && (s[hi - 1] == ' ' || s[hi - 1] == '\t'))
        --hi;
    return s[lo .. hi];
}

private string[] splitWords(string s)
{
    string[] r;
    size_t i = 0;
    while (i < s.length)
    {
        while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
            ++i;
        const start = i;
        while (i < s.length && s[i] != ' ' && s[i] != '\t')
            ++i;
        if (i > start)
            r ~= s[start .. i];
    }
    return r;
}

/// Renders a build's event lines and result line (without the header).
string formatBuildResult(const BuildResult r)
{
    auto o = appender!string;
    foreach (ref e; r.events)
    {
        final switch (e.kind)
        {
        case Event.Kind.hit:
            o ~= "  hit " ~ e.start.to!string ~ " " ~ e.target ~ "\n";
            break;
        case Event.Kind.run:
        case Event.Kind.fail:
        case Event.Kind.cancel:
            const word = e.kind == Event.Kind.run ? "run" : (e.kind == Event.Kind.fail ? "fail" : "cancel");
            o ~= "  " ~ word ~ " " ~ e.start.to!string ~ " " ~ e.end.to!string ~ " w" ~ e.worker.to!string
                ~ " " ~ e.target ~ " " ~ e.command ~ "\n";
            break;
        }
    }
    if (r.error !is null)
        o ~= "  error " ~ r.error.msg ~ "\n";
    else
        o ~= "  ok ran=" ~ r.ran.to!string ~ " hit=" ~ r.hits.to!string ~ " time=" ~ r.time.to!string ~ "\n";
    return o.data;
}

/**
 * Runs a whole session against `fs` and returns the text of `log.txt`.
 *
 * `fs` is left holding the final workspace.
 */
string runSession(Vfs fs, const(SessionStep)[] steps)
{
    auto log = appender!string;
    foreach (n, ref s; steps)
    {
        log ~= "step " ~ (n + 1).to!string ~ ": ";
        final switch (s.kind)
        {
        case SessionStep.Kind.build:
            log ~= "build ";
            foreach (t; s.targets)
                log ~= t ~ " ";
            if (s.targets.length == 0)
                log ~= "(default) ";
            log ~= "-j " ~ s.workers.to!string ~ "\n";
            log ~= formatBuildResult(runBuild(fs, s.targets, s.workers));
            break;
        case SessionStep.Kind.create:
        case SessionStep.Kind.edit:
            log ~= (s.kind == SessionStep.Kind.create ? "create " : "edit ") ~ s.path ~ "\n";
            fs.write(s.path, s.content);
            log ~= "  ok size=" ~ s.content.length.to!string ~ "\n";
            break;
        case SessionStep.Kind.delete_:
            log ~= "delete " ~ s.path ~ "\n";
            fs.remove(s.path);
            log ~= "  ok\n";
            break;
        case SessionStep.Kind.touch:
            log ~= "touch " ~ s.path ~ "\n";
            fs.touch(s.path);
            log ~= "  ok\n";
            break;
        case SessionStep.Kind.clean:
            log ~= "clean\n";
            string[] removed;
            foreach (p; fs.paths())
                if (isGeneratedPath(p) || p == stateFilePath)
                    removed ~= p;
            foreach (p; removed)
            {
                fs.remove(p);
                log ~= "  remove " ~ p ~ "\n";
            }
            log ~= "  ok removed=" ~ removed.length.to!string ~ "\n";
            break;
        }
    }
    return log.data;
}

version (unittest)
{
    private string session(string[string] files, string script)
    {
        auto fs = new Vfs;
        foreach (k, v; files)
            fs.write(k, v);
        return runSession(fs, parseSession(script));
    }
}

unittest
{
    auto steps = parseSession("# c\n\n  build a b -j 4\nbuild -j 2\nbuild x -j\ncreate p\n  keep \n\n# not a comment\n---\nclean\n");
    assert(steps.length == 5);
    assert(steps[0].targets == ["a", "b"] && steps[0].workers == 4);
    assert(steps[1].targets.length == 0 && steps[1].workers == 2);
    assert(steps[2].targets == ["x", "-j"] && steps[2].workers == 1);
    assert(steps[3].content == "  keep \n\n# not a comment\n");
    assert(steps[4].kind == SessionStep.Kind.clean);
}

unittest
{
    enum one = "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n";
    const log = session(["main.kiln": one], "build\nbuild\ntouch main.kiln\nbuild\nclean\nbuild\n");
    assert(log == "step 1: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n"
            ~ "step 2: build (default) -j 1\n  hit 0 out/hello.txt\n  ok ran=0 hit=1 time=0\n"
            ~ "step 3: touch main.kiln\n  ok\n"
            ~ "step 4: build (default) -j 1\n  hit 0 out/hello.txt\n  ok ran=0 hit=1 time=0\n"
            ~ "step 5: clean\n  remove .kiln-state\n  remove out/hello.txt\n  ok removed=2\n"
            ~ "step 6: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n");
}

unittest
{
    // Example 3: worker allocation and tie-breaking.
    enum main = "step {\n out \"out/a.txt\"\n cmd write(\"A\\n\")\n cost 3\n}\n"
        ~ "step {\n out \"out/b.txt\"\n cmd write(\"B\\n\")\n cost 1\n}\n"
        ~ "step {\n out \"out/c.txt\"\n cmd write(\"C\\n\")\n cost 4\n}\n"
        ~ "step {\n out \"out/d.txt\"\n cmd write(\"D\\n\")\n cost 2\n}\n"
        ~ "step {\n out \"out/all.txt\"\n in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]\n cmd concat()\n cost 2\n}\n"
        ~ "default \"out/all.txt\"\n";
    assert(session(["main.kiln": main], "build -j 2\n")
            == "step 1: build (default) -j 2\n  run 0 3 w0 out/a.txt write(\"A\\n\")\n  run 0 1 w1 out/b.txt write(\"B\\n\")\n"
            ~ "  run 1 5 w1 out/c.txt write(\"C\\n\")\n  run 3 5 w0 out/d.txt write(\"D\\n\")\n"
            ~ "  run 5 7 w0 out/all.txt concat()\n  ok ran=5 hit=0 time=7\n");
}

unittest
{
    // Example 8: early cutoff.
    enum main = "step {\n out \"out/mid.txt\"\n in \"src/a.txt\"\n cmd upper()\n}\n"
        ~ "step {\n out \"out/final.txt\"\n in \"out/mid.txt\"\n cmd number()\n}\ndefault \"out/final.txt\"\n";
    assert(session(["main.kiln": main, "src/a.txt": "abc\n"], "build\nedit src/a.txt\nABC\n---\nbuild\n")
            == "step 1: build (default) -j 1\n  run 0 2 w0 out/mid.txt upper()\n  run 2 4 w0 out/final.txt number()\n  ok ran=2 hit=0 time=4\n"
            ~ "step 2: edit src/a.txt\n  ok size=4\n"
            ~ "step 3: build (default) -j 1\n  run 0 2 w0 out/mid.txt upper()\n  hit 2 out/final.txt\n  ok ran=1 hit=1 time=2\n");
}

unittest
{
    // Example 12: an execution error cancels work in flight.
    enum main = "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\n"
        ~ "step {\n out \"out/slow.txt\"\n cmd write(\"slow\\n\")\n cost 10\n}\n"
        ~ "step {\n out \"out/after.txt\"\n in \"out/doc.txt\"\n cmd copy()\n}\n"
        ~ "phony all = [\"out/doc.txt\", \"out/slow.txt\", \"out/after.txt\"]\ndefault \"@all\"\n";
    auto fs = new Vfs;
    fs.write("main.kiln", main);
    fs.write("src/main.txt", "@need src/gone.txt\n");
    assert(runSession(fs, parseSession("build -j 2\n"))
            == "step 1: build (default) -j 2\n  fail 0 6 w0 out/doc.txt preprocess()\n"
            ~ "  cancel 0 10 w1 out/slow.txt write(\"slow\\n\")\n"
            ~ "  error E_NEED_MISSING src/gone.txt needed by src/main.txt\n");
    assert(fs.read(".kiln-state") == "kiln-state 1\n" && !fs.exists("out/slow.txt"));
}
