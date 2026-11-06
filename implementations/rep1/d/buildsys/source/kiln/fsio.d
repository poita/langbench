/// Loading a workspace from a real directory and writing the session output.
module kiln.fsio;

import std.file;
import std.path;

import kiln.vfs;

/// A loaded input directory.
struct Session
{
    Vfs vfs; /// the initial workspace
    string script; /// the content of `session.txt`
}

/// Walks `inputDir`, loading every regular file except the top-level `session.txt`.
Session loadInput(string inputDir)
{
    Session s;
    s.vfs = new Vfs;
    s.script = cast(string) std.file.read(buildPath(inputDir, "session.txt"));
    foreach (entry; dirEntries(inputDir, SpanMode.depth))
    {
        if (!entry.isFile)
            continue;
        const rel = relativePath(entry.name, inputDir);
        if (rel == "session.txt")
            continue;
        s.vfs.put(rel, cast(string) std.file.read(entry.name));
    }
    return s;
}

/// Writes `log.txt` and the final workspace under `outDir`.
void writeOutput(string outDir, string log, Vfs vfs)
{
    mkdirRecurse(outDir);
    std.file.write(buildPath(outDir, "log.txt"), log);
    const root = buildPath(outDir, "workspace");
    bool[string] made;
    foreach (p; vfs.paths())
    {
        const full = buildPath(root, p);
        const dir = dirName(full);
        if (dir !in made)
        {
            mkdirRecurse(dir);
            made[dir] = true;
        }
        std.file.write(full, vfs.content(p));
    }
}
