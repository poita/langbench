/// Session scripts: parsing `session.txt` and running a whole session,
/// producing the text of `log.txt`.
module kiln.session;

import kiln.build;
import kiln.bytes;
import kiln.vfs;

/// Kinds of session step.
enum StepKind : ubyte { build, create, edit, del, touch, clean }

/// One parsed session step.
struct SessionStep
{
    StepKind kind;
    string path;        /// create/edit/delete/touch
    string content;     /// create/edit
    string[] targets;   /// build
    int workers = 1;    /// build
}

private bool isBlankOrTab(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t';
}

private string[] splitWords(string line) pure nothrow
{
    string[] words;
    size_t i = 0;
    while (i < line.length)
    {
        while (i < line.length && isBlankOrTab(line[i]))
            ++i;
        size_t j = i;
        while (j < line.length && !isBlankOrTab(line[j]))
            ++j;
        if (j > i)
            words ~= line[i .. j];
        i = j;
    }
    return words;
}

/// Parse the text of a `session.txt`.
SessionStep[] parseSession(string text)
{
    import std.conv : to;
    SessionStep[] steps;
    string[] lines;
    {
        size_t start = 0;
        foreach (i; 0 .. text.length)
            if (text[i] == '\n')
            {
                lines ~= text[start .. i];
                start = i + 1;
            }
        if (start < text.length)
            lines ~= text[start .. $];
    }
    size_t li = 0;
    while (li < lines.length)
    {
        auto words = splitWords(lines[li++]);
        if (words.length == 0 || words[0][0] == '#')
            continue;
        SessionStep s;
        switch (words[0])
        {
        case "build":
            s.kind = StepKind.build;
            auto ws = words[1 .. $];
            if (ws.length >= 2 && ws[$ - 2] == "-j")
            {
                s.workers = ws[$ - 1].to!int;
                ws = ws[0 .. $ - 2];
            }
            s.targets = ws;
            break;
        case "create", "edit":
        {
            s.kind = words[0] == "create" ? StepKind.create : StepKind.edit;
            s.path = words.length > 1 ? words[1] : "";
            Buf b;
            while (li < lines.length && lines[li] != "---")
            {
                b.put(lines[li++]);
                b.putc('\n');
            }
            ++li; // the terminator
            s.content = b.take();
            break;
        }
        case "delete":
            s.kind = StepKind.del;
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
            continue; // not a defined step; ignored
        }
        steps ~= s;
    }
    return steps;
}

/// Append the log block of a finished build.
void formatBuild(ref Buf log, const ref BuildReport rep)
{
    foreach (ref ev; rep.events)
    {
        final switch (ev.kind)
        {
        case EventKind.hit:
            log.put("  hit ");
            log.putInt(ev.start);
            log.putc(' ');
            log.put(ev.target);
            break;
        case EventKind.run:
        case EventKind.fail:
        case EventKind.cancel:
            log.put(ev.kind == EventKind.run ? "  run " : (ev.kind == EventKind.fail ? "  fail " : "  cancel "));
            log.putInt(ev.start);
            log.putc(' ');
            log.putInt(ev.end);
            log.put(" w");
            log.putInt(ev.worker);
            log.putc(' ');
            log.put(ev.target);
            log.putc(' ');
            log.put(ev.command);
            break;
        }
        log.putc('\n');
    }
    if (rep.error !is null)
    {
        log.put("  error ");
        log.put(rep.error.render());
    }
    else
    {
        log.put("  ok ran=");
        log.putInt(rep.ran);
        log.put(" hit=");
        log.putInt(rep.hits);
        log.put(" time=");
        log.putInt(rep.time);
    }
    log.putc('\n');
}

/// Run a parsed session against `vfs` and return the log text.
string runSession(Vfs vfs, const(SessionStep)[] steps)
{
    Buf log;
    foreach (i, ref s; steps)
    {
        log.put("step ");
        log.putInt(i + 1);
        log.put(": ");
        final switch (s.kind)
        {
        case StepKind.build:
            log.put("build");
            if (s.targets.length == 0)
                log.put(" (default)");
            foreach (t; s.targets)
            {
                log.putc(' ');
                log.put(t);
            }
            log.put(" -j ");
            log.putInt(s.workers);
            log.putc('\n');
            auto rep = runBuild(vfs, s.targets.dup, s.workers);
            formatBuild(log, rep);
            break;
        case StepKind.create:
        case StepKind.edit:
            log.put(s.kind == StepKind.create ? "create " : "edit ");
            log.put(s.path);
            log.putc('\n');
            vfs.write(s.path, s.content);
            log.put("  ok size=");
            log.putInt(s.content.length);
            log.putc('\n');
            break;
        case StepKind.del:
            log.put("delete ");
            log.put(s.path);
            log.put("\n");
            vfs.remove(s.path);
            log.put("  ok\n");
            break;
        case StepKind.touch:
            log.put("touch ");
            log.put(s.path);
            log.put("\n");
            vfs.touch(s.path);
            log.put("  ok\n");
            break;
        case StepKind.clean:
            log.put("clean\n");
            auto gone = vfs.clean();
            foreach (p; gone)
            {
                log.put("  remove ");
                log.put(p);
                log.putc('\n');
            }
            log.put("  ok removed=");
            log.putInt(gone.length);
            log.putc('\n');
            break;
        }
    }
    return log.take();
}

/// Parse and run a session script.
string runSession(Vfs vfs, string sessionText)
{
    return runSession(vfs, parseSession(sessionText));
}
