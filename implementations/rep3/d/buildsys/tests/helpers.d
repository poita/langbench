/// Shared helpers for the unit tests.
module tests.helpers;

import kiln;

/// A workspace holding the given files.
Vfs workspace(string[string] files)
{
    auto v = new Vfs;
    foreach (p, c; files)
        v.write(p, c);
    return v;
}

/// Run a session against a workspace built from `files`; returns the log.
string logOf(string[string] files, string session, Vfs* outVfs = null)
{
    auto v = workspace(files);
    auto log = runSession(v, session);
    if (outVfs !is null)
        *outVfs = v;
    return log;
}

/// Evaluate the build files only; returns the error rendering, or "" on success.
string configError(string[string] files)
{
    auto v = workspace(files);
    try
        evaluateBuild(v);
    catch (KilnError e)
        return e.render();
    return "";
}

/// Evaluate and validate the graph (default targets); returns the error rendering or "".
string graphError(string[string] files, string[] targets = null)
{
    auto v = workspace(files);
    try
    {
        auto plan = evaluateBuild(v);
        buildGraph(plan, v, targets);
    }
    catch (KilnError e)
        return e.render();
    return "";
}
