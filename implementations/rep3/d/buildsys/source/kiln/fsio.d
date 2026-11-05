/// Loading a workspace from a real directory and writing it back.
module kiln.fsio;

import std.file;
import std.path : buildPath, dirName;
import kiln.vfs;

/// Result of loading an input directory.
struct LoadedInput
{
    Vfs workspace;
    string sessionText;
}

/// Read an input directory: `session.txt` at the top level becomes
/// `sessionText`; every other regular file becomes a workspace file.
LoadedInput loadInput(string dir)
{
    LoadedInput r;
    r.workspace = new Vfs;
    foreach (DirEntry e; dirEntries(dir, SpanMode.depth, false))
    {
        if (!e.isFile)
            continue;
        string rel = e.name[dir.length .. $];
        while (rel.length && rel[0] == '/')
            rel = rel[1 .. $];
        auto data = cast(string) std.file.read(e.name);
        if (rel == "session.txt")
            r.sessionText = data;
        else
            r.workspace.write(rel, data);
    }
    return r;
}

/// Write every workspace file under `outDir/workspace/`.
void writeWorkspace(Vfs vfs, string outDir)
{
    auto root = buildPath(outDir, "workspace");
    mkdirRecurse(root);
    bool[string] made;
    foreach (p; vfs.allPaths())
    {
        auto full = buildPath(root, p);
        auto d = dirName(full);
        if (d !in made)
        {
            mkdirRecurse(d);
            made[d] = true;
        }
        std.file.write(full, vfs.read(p));
    }
}
