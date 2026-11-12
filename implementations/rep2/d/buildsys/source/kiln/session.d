/**
 * Session scripts: a sequence of builds and workspace mutations, and the log
 * that records everything that happened.
 */
module kiln.session;

import kiln.build : BuildReport, runBuild;
import kiln.bytes : decimal;
import kiln.scheduler : Event, EventKind;
import kiln.workspace : Workspace;

/// The kinds of session step.
enum StepKind : ubyte
{
    build,
    create,
    edit,
    remove,
    touch,
    clean,
}

/// One step of a session script.
struct SessionStep
{
    StepKind kind;
    /// `build` targets as written.
    string[] targets;
    /// `build` worker count.
    int workers = 1;
    /// Path for create/edit/delete/touch.
    string path;
    /// New content for create/edit.
    string content;
}

private bool isBlank(const(char)[] s) @safe pure nothrow @nogc
{
    foreach (c; s)
        if (c != ' ' && c != '\t')
            return false;
    return true;
}

private string[] splitWords(string line) @safe pure nothrow
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

private int parseWorkers(string w) @safe pure nothrow @nogc
{
    int n = 0;
    foreach (c; w)
    {
        if (c < '0' || c > '9')
            return 1;
        n = n * 10 + (c - '0');
        if (n > 1_000_000)
            break;
    }
    return n < 1 ? 1 : n;
}

/// Parses `session.txt` text into steps.
SessionStep[] parseSession(string text) @safe pure nothrow
{
    import kiln.bytes : splitLines;

    SessionStep[] steps;
    auto lines = splitLines(text);
    size_t i = 0;
    while (i < lines.length)
    {
        auto raw = lines[i++];
        if (isBlank(raw))
            continue;
        auto words = splitWords(raw);
        if (words[0][0] == '#')
            continue;
        SessionStep st;
        switch (words[0])
        {
        case "build":
            st.kind = StepKind.build;
            auto rest = words[1 .. $];
            if (rest.length >= 2 && rest[$ - 2] == "-j")
            {
                st.workers = parseWorkers(rest[$ - 1]);
                rest = rest[0 .. $ - 2];
            }
            st.targets = rest;
            break;
        case "create":
        case "edit":
            st.kind = words[0] == "create" ? StepKind.create : StepKind.edit;
            st.path = words.length > 1 ? words[1] : "";
            char[] content;
            while (i < lines.length && lines[i] != "---")
            {
                content ~= lines[i++];
                content ~= '\n';
            }
            if (i < lines.length)
                i++; // the terminator
            st.content = (() @trusted => cast(string) content)();
            break;
        case "delete":
            st.kind = StepKind.remove;
            st.path = words.length > 1 ? words[1] : "";
            break;
        case "touch":
            st.kind = StepKind.touch;
            st.path = words.length > 1 ? words[1] : "";
            break;
        case "clean":
            st.kind = StepKind.clean;
            break;
        default:
            continue; // not a well-formed step: ignored
        }
        steps ~= st;
    }
    return steps;
}

private void eventLine(ref char[] log, ref const Event e) @safe pure nothrow
{
    final switch (e.kind)
    {
    case EventKind.hit:
        log ~= "  hit " ~ decimal(e.start) ~ " " ~ e.target ~ "\n";
        break;
    case EventKind.run:
    case EventKind.fail:
    case EventKind.cancel:
        immutable word = e.kind == EventKind.run ? "run" : (e.kind == EventKind.fail ? "fail" : "cancel");
        log ~= "  " ~ word ~ " " ~ decimal(e.start) ~ " " ~ decimal(e.end) ~ " w"
            ~ decimal(e.worker) ~ " " ~ e.target ~ " " ~ e.command ~ "\n";
        break;
    }
}

/**
 * Runs `steps` against `ws` and returns the text of `log.txt`.
 */
string runSession(Workspace ws, const(SessionStep)[] steps) @safe
{
    char[] log;
    foreach (n, ref st; steps)
    {
        immutable head = "step " ~ decimal(n + 1) ~ ": ";
        final switch (st.kind)
        {
        case StepKind.build:
            {
                string targets;
                foreach (t; st.targets)
                    targets ~= t ~ " ";
                if (st.targets.length == 0)
                    targets = "(default) ";
                log ~= head ~ "build " ~ targets ~ "-j " ~ decimal(st.workers) ~ "\n";
                auto rep = runBuild(ws, st.targets, st.workers);
                foreach (ref e; rep.events)
                    eventLine(log, e);
                if (rep.error !is null)
                    log ~= "  error " ~ rep.error.render() ~ "\n";
                else
                    log ~= "  ok ran=" ~ decimal(rep.ran) ~ " hit=" ~ decimal(rep.hits)
                        ~ " time=" ~ decimal(rep.time) ~ "\n";
                break;
            }
        case StepKind.create:
        case StepKind.edit:
            log ~= head ~ (st.kind == StepKind.create ? "create " : "edit ") ~ st.path ~ "\n";
            ws.write(st.path, st.content);
            log ~= "  ok size=" ~ decimal(st.content.length) ~ "\n";
            break;
        case StepKind.remove:
            log ~= head ~ "delete " ~ st.path ~ "\n";
            ws.remove(st.path);
            log ~= "  ok\n";
            break;
        case StepKind.touch:
            log ~= head ~ "touch " ~ st.path ~ "\n";
            ws.touch(st.path);
            log ~= "  ok\n";
            break;
        case StepKind.clean:
            {
                log ~= head ~ "clean\n";
                auto gone = ws.clean();
                foreach (p; gone)
                    log ~= "  remove " ~ p ~ "\n";
                log ~= "  ok removed=" ~ decimal(gone.length) ~ "\n";
                break;
            }
        }
    }
    return (() @trusted => cast(string) log)();
}

/// Parses `sessionText` and runs it: a convenience for callers holding the script as text.
string runSession(Workspace ws, string sessionText) @safe
{
    return runSession(ws, parseSession(sessionText));
}
