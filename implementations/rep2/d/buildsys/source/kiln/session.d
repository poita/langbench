/**
 * Session scripts: parsing `session.txt`, replaying it against a workspace
 * and rendering the log.
 */
module kiln.session;

import kiln.build;
import kiln.paths;
import kiln.vfs;

import std.array : appender, Appender;
import std.conv : to;

/// Kinds of session step.
enum StepKind : ubyte
{
    build,
    create,
    edit,
    delete_,
    touch,
    clean,
}

/// One parsed session step.
struct SessionStep
{
    StepKind kind;
    /// `build`: the targets as written.
    string[] targets;
    /// `build`: worker count.
    int workers = 1;
    /// `create` / `edit` / `delete` / `touch`: the path.
    string path;
    /// `create` / `edit`: the new content.
    string content;
}

private bool isBlank(const(char)[] s) @safe pure nothrow @nogc
{
    foreach (c; s)
        if (c != ' ' && c != '\t')
            return false;
    return true;
}

private string[] splitWords(string line)
{
    string[] words;
    size_t i = 0;
    while (i < line.length)
    {
        while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
            i++;
        size_t j = i;
        while (j < line.length && line[j] != ' ' && line[j] != '\t')
            j++;
        if (j > i)
            words ~= line[i .. j];
        i = j;
    }
    return words;
}

/// Parses the text of a `session.txt`.
SessionStep[] parseSession(string text)
{
    SessionStep[] steps;
    string[] lines;
    size_t start = 0;
    foreach (i; 0 .. text.length)
        if (text[i] == '\n')
        {
            lines ~= text[start .. i];
            start = i + 1;
        }
    if (start < text.length)
        lines ~= text[start .. $];

    size_t li = 0;
    while (li < lines.length)
    {
        auto line = lines[li++];
        if (isBlank(line))
            continue;
        auto words = splitWords(line);
        if (words[0].length && words[0][0] == '#')
            continue;
        SessionStep s;
        switch (words[0])
        {
        case "build":
        {
            s.kind = StepKind.build;
            auto rest = words[1 .. $];
            if (rest.length >= 2 && rest[$ - 2] == "-j")
            {
                s.workers = rest[$ - 1].to!int;
                rest = rest[0 .. $ - 2];
            }
            s.targets = rest;
            break;
        }
        case "create":
        case "edit":
        {
            s.kind = words[0] == "create" ? StepKind.create : StepKind.edit;
            s.path = words.length > 1 ? words[1] : "";
            auto app = appender!(char[]);
            while (li < lines.length && lines[li] != "---")
            {
                app.put(lines[li]);
                app.put('\n');
                li++;
            }
            li++; // the terminator
            s.content = (() @trusted => cast(string) app.data)();
            break;
        }
        case "delete":
            s.kind = StepKind.delete_;
            s.path = words[1];
            break;
        case "touch":
            s.kind = StepKind.touch;
            s.path = words[1];
            break;
        case "clean":
            s.kind = StepKind.clean;
            break;
        default:
            continue;
        }
        steps ~= s;
    }
    return steps;
}

/// Appends the event lines and the result line of a build to `log`.
void appendBuildLines(ref Appender!(char[]) log, const ref BuildReport rep)
{
    static immutable string[] names = ["hit", "run", "fail", "cancel"];
    foreach (ref e; rep.events)
    {
        log.put("  ");
        log.put(names[e.kind]);
        log.put(' ');
        if (e.kind == EventKind.hit)
        {
            log.put(e.start.to!string);
            log.put(' ');
            log.put(e.target);
        }
        else
        {
            log.put(e.start.to!string);
            log.put(' ');
            log.put(e.end.to!string);
            log.put(" w");
            log.put(e.worker.to!string);
            log.put(' ');
            log.put(e.target);
            log.put(' ');
            log.put(e.command);
        }
        log.put('\n');
    }
    if (rep.ok)
    {
        log.put("  ok ran=");
        log.put(rep.ran.to!string);
        log.put(" hit=");
        log.put(rep.hits.to!string);
        log.put(" time=");
        log.put(rep.time.to!string);
    }
    else
    {
        log.put("  error ");
        log.put(rep.error.render());
    }
    log.put('\n');
}

/**
 * Replays a session against `vfs` and returns the log text.
 */
string runSession(Vfs vfs, const(SessionStep)[] steps)
{
    import kiln.build : runBuild;

    auto log = appender!(char[]);
    foreach (idx, ref s; steps)
    {
        log.put("step ");
        log.put((idx + 1).to!string);
        log.put(": ");
        final switch (s.kind)
        {
        case StepKind.build:
        {
            log.put("build");
            if (s.targets.length == 0)
                log.put(" (default)");
            foreach (t; s.targets)
            {
                log.put(' ');
                log.put(t);
            }
            log.put(" -j ");
            log.put(s.workers.to!string);
            log.put('\n');
            auto rep = runBuild(vfs, s.targets, s.workers);
            appendBuildLines(log, rep);
            break;
        }
        case StepKind.create:
        case StepKind.edit:
            log.put(s.kind == StepKind.create ? "create " : "edit ");
            log.put(s.path);
            log.put('\n');
            vfs.write(s.path, s.content);
            log.put("  ok size=");
            log.put(s.content.length.to!string);
            log.put('\n');
            break;
        case StepKind.delete_:
            log.put("delete ");
            log.put(s.path);
            log.put('\n');
            vfs.remove(s.path);
            log.put("  ok\n");
            break;
        case StepKind.touch:
            log.put("touch ");
            log.put(s.path);
            log.put('\n');
            vfs.touch(s.path);
            log.put("  ok\n");
            break;
        case StepKind.clean:
        {
            log.put("clean\n");
            auto gone = vfs.clean();
            foreach (p; gone)
            {
                log.put("  remove ");
                log.put(p);
                log.put('\n');
            }
            log.put("  ok removed=");
            log.put(gone.length.to!string);
            log.put('\n');
            break;
        }
        }
    }
    return (() @trusted => cast(string) log.data)();
}
