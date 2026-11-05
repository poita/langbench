/// Shared helpers for the unit tests.
module helpers;

import kiln;
import kiln.interp : Evaluator;

/// A workspace pre-populated from a path -> content map.
Vfs workspace(string[string] files)
{
    auto v = new Vfs;
    foreach (p, c; files)
        v.write(p, c);
    return v;
}

/// Replays `session` on a workspace and returns the log.
string replay(Vfs v, string session)
{
    return runSession(v, parseSession(session));
}

/// Evaluates a KBL expression and returns its string form, or
/// `!E_KIND detail` when evaluation raised an error.
string evalExpr(string expr, string[string] files = null)
{
    auto v = workspace(files);
    v.write("main.kiln", "let r = " ~ expr ~ "\nabort \"{r}\"\n");
    try
    {
        new Evaluator(v).run("main.kiln");
    }
    catch (KilnError e)
    {
        return e.kind == "E_ABORT" ? e.detail : "!" ~ e.render();
    }
    assert(0, "abort did not fire");
}

/// Evaluates build-file text (as `main.kiln`) and returns the error text, or
/// an empty string when it ran cleanly.
string evalFile(string text, string[string] files = null)
{
    auto v = workspace(files);
    v.write("main.kiln", text);
    try
    {
        new Evaluator(v).run("main.kiln");
    }
    catch (KilnError e)
        return e.render();
    return "";
}
