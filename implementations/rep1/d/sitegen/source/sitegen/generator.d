/// The top-level driver: read a site directory, write the generated site.
module sitegen.generator;

import sitegen.render;
import sitegen.source_;
import std.file;
import std.path : buildPath, dirName;

private final class DirectoryWriter
{
    private string root;
    private bool[string] made;

    this(string root)
    {
        this.root = root;
    }

    private void ensureDir(string dir)
    {
        if (dir in made)
            return;
        mkdirRecurse(dir);
        made[dir] = true;
    }

    void write(string relPath, const(void)[] data)
    {
        string full = buildPath(root, relPath);
        ensureDir(dirName(full));
        std.file.write(full, data);
    }
}

/// Copy every file under `staticDir` (at any depth, dot files included) into
/// the output directory at the same relative path.
private void copyStatic(string staticDir, DirectoryWriter out_)
{
    if (!exists(staticDir) || !isDir(staticDir))
        return;
    foreach (entry; dirEntries(staticDir, SpanMode.breadth))
    {
        if (!entry.isFile)
            continue;
        string rel = entry.name[staticDir.length + 1 .. $];
        out_.write(rel, read(entry.name));
    }
}

/// Generate the site found in `inputDir` into `outputDir`.
///
/// Throws on unreadable input, malformed front matter or template errors.
void generateSite(string inputDir, string outputDir)
{
    auto src = readSiteSource(inputDir);
    auto writer = new DirectoryWriter(outputDir);
    mkdirRecurse(outputDir);
    foreach (ref f; renderSite(src))
        writer.write(f.path, f.content);
    copyStatic(buildPath(inputDir, "static"), writer);
}
