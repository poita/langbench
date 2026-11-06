/// The session driver: parses `session.txt`, applies each step and writes the log.
module kiln.session;

import std.algorithm.sorting : sort;
import std.conv : to;

import kiln.build;
import kiln.bytes : decimal;
import kiln.paths;
import kiln.vfs;

/// Runs a whole session script against `vfs` and returns the text of `log.txt`.
string runSession(Vfs vfs, string script) @safe
{
    char[] log;
    int stepNo = 0;

    string[] lines;
    size_t pos = 0;
    while (pos < script.length)
    {
        size_t e = pos;
        while (e < script.length && script[e] != '\n')
            ++e;
        lines ~= script[pos .. e];
        pos = e + 1;
    }

    void emit(string s)
    {
        log ~= s;
        log ~= '\n';
    }

    size_t li = 0;
    while (li < lines.length)
    {
        auto raw = lines[li++];
        auto words = splitWords(raw);
        if (words.length == 0 || words[0][0] == '#')
            continue;
        ++stepNo;
        const head = "step " ~ decimal(stepNo) ~ ": ";
        switch (words[0])
        {
        case "build":
            {
                string[] targets = words[1 .. $];
                int n = 1;
                if (words.length >= 3 && words[$ - 2] == "-j")
                {
                    n = words[$ - 1].to!int;
                    targets = words[1 .. $ - 2];
                }
                string hdr = head ~ "build";
                if (targets.length == 0)
                    hdr ~= " (default)";
                foreach (t; targets)
                    hdr ~= " " ~ t;
                emit(hdr ~ " -j " ~ decimal(n));
                renderBuild(log, runBuild(vfs, targets, n));
                break;
            }
        case "create":
        case "edit":
            {
                char[] content;
                while (li < lines.length)
                {
                    auto l = lines[li++];
                    if (l == "---")
                        break;
                    content ~= l;
                    content ~= '\n';
                }
                const path = words.length > 1 ? words[1] : "";
                emit(head ~ words[0] ~ " " ~ path);
                const size = content.length;
                vfs.put(path, (() @trusted => cast(string) content)());
                emit("  ok size=" ~ decimal(cast(long) size));
                break;
            }
        case "delete":
            emit(head ~ "delete " ~ words[1]);
            vfs.remove(words[1]);
            emit("  ok");
            break;
        case "touch":
            emit(head ~ "touch " ~ words[1]);
            vfs.touch(words[1]);
            emit("  ok");
            break;
        case "clean":
            {
                emit(head ~ "clean");
                string[] gone;
                foreach (p; vfs.paths())
                    if (isOutPath(p) || p == stateFileName)
                        gone ~= p;
                foreach (p; gone)
                {
                    emit("  remove " ~ p);
                    vfs.remove(p);
                }
                emit("  ok removed=" ~ decimal(cast(long) gone.length));
                break;
            }
        default:
            --stepNo;
            break;
        }
    }
    return (() @trusted => cast(string) log)();
}

private string[] splitWords(string line) @safe
{
    string[] words;
    size_t i = 0;
    while (i < line.length)
    {
        while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
            ++i;
        const s = i;
        while (i < line.length && line[i] != ' ' && line[i] != '\t')
            ++i;
        if (i > s)
            words ~= line[s .. i];
    }
    return words;
}

private void renderBuild(ref char[] log, const BuildReport rep) @safe
{
    foreach (ref e; rep.events)
    {
        final switch (e.kind)
        {
        case Event.Kind.hit:
            log ~= "  hit " ~ decimal(e.start) ~ " " ~ e.target ~ "\n";
            break;
        case Event.Kind.run:
        case Event.Kind.fail:
        case Event.Kind.cancel:
            const tag = e.kind == Event.Kind.run ? "run" : (e.kind == Event.Kind.fail ? "fail"
                    : "cancel");
            log ~= "  " ~ tag ~ " " ~ decimal(e.start) ~ " " ~ decimal(e.end) ~ " w"
                ~ decimal(e.worker) ~ " " ~ e.target ~ " " ~ e.command ~ "\n";
            break;
        }
    }
    if (rep.ok)
        log ~= "  ok ran=" ~ decimal(rep.ran) ~ " hit=" ~ decimal(rep.hits) ~ " time="
            ~ decimal(rep.time) ~ "\n";
    else
        log ~= "  error " ~ rep.error ~ "\n";
}
