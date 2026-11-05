/// Shared helpers for the unit tests.
module helpers;

import kiln.build;
import kiln.session;
import kiln.vfs;

/// A workspace built from `(path, content)` pairs.
Vfs workspace(string[string] files)
{
    auto v = new Vfs;
    foreach (k, c; files)
        v.put(k, c);
    return v;
}

/// Runs a session script against the given files and returns the log.
string session(string[string] files, string script, Vfs* outVfs = null)
{
    auto v = workspace(files);
    auto log = runSession(v, script);
    if (outVfs)
        *outVfs = v;
    return log;
}

/// Builds `main` once with default targets and returns the report.
BuildReport buildOnce(string main, string[string] extra = null)
{
    string[string] files = ["main.kiln": main];
    foreach (k, c; extra)
        files[k] = c;
    return runBuild(workspace(files), [], 1);
}
