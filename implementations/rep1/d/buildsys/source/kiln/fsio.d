/**
 * Loading a workspace from a real directory and writing the final workspace back.
 */
module kiln.fsio;

import std.file;
import std.path : buildPath, dirName;
import std.string : replace;

import kiln.vfs;

/// Name of the session script, which is not part of the workspace.
enum sessionFileName = "session.txt";

/**
 * Loads every regular file below `dir` into a new `Vfs`, except the top-level
 * `session.txt`.
 */
Vfs loadWorkspace(string dir)
{
    auto fs = new Vfs;
    foreach (entry; dirEntries(dir, SpanMode.depth))
    {
        if (!entry.isFile)
            continue;
        string rel = entry.name[dir.length .. $];
        while (rel.length && rel[0] == '/')
            rel = rel[1 .. $];
        if (rel == sessionFileName)
            continue;
        fs.write(rel, cast(string) read(entry.name));
    }
    return fs;
}

/// Writes every file of `fs` to `<outDir>/workspace/<path>`.
void writeWorkspace(Vfs fs, string outDir)
{
    const root = buildPath(outDir, "workspace");
    foreach (p; fs.paths())
    {
        const full = buildPath(root, p);
        mkdirRecurse(dirName(full));
        std.file.write(full, fs.read(p));
    }
}
