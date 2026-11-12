/**
 * Reading a site's source directory.
 */
module sitegen.source;

import std.algorithm.searching : endsWith;
import std.algorithm.sorting : sort;
import std.array : array;
import std.file : DirEntry, SpanMode, dirEntries, exists, isDir, isFile, read;
import std.path : baseName, buildPath;

/// A file of the source site: its name within its directory and its text.
struct SourceFile
{
    string name;
    string text;
}

/// The in-memory form of a site's source, apart from the static files.
struct SiteSource
{
    /// The text of `site.toml`.
    string config;
    /// The files of `content/posts`.
    SourceFile[] posts;
    /// The files of `content/pages`.
    SourceFile[] pages;
    /// The files of `templates`.
    SourceFile[] templates;
    /// The `static` directory, or `null` if the site has none.
    string staticDir;
}

private string readString(string path)
{
    return cast(string) read(path);
}

private SourceFile[] readDirectory(string dir, string suffix)
{
    SourceFile[] files;
    if (!exists(dir) || !isDir(dir)) return files;
    foreach (DirEntry e; dirEntries(dir, SpanMode.shallow))
    {
        const name = baseName(e.name);
        if (!name.endsWith(suffix) || !e.isFile) continue;
        files ~= SourceFile(name, readString(e.name));
    }
    files.sort!((a, b) => a.name < b.name);
    return files;
}

/**
 * Reads the site in directory `dir`.
 *
 * Throws: `FileException` if `site.toml` cannot be read.
 */
SiteSource loadSource(string dir)
{
    SiteSource src;
    src.config = readString(buildPath(dir, "site.toml"));
    src.posts = readDirectory(buildPath(dir, "content", "posts"), ".md");
    src.pages = readDirectory(buildPath(dir, "content", "pages"), ".md");
    src.templates = readDirectory(buildPath(dir, "templates"), ".html");
    const staticDir = buildPath(dir, "static");
    if (exists(staticDir) && isDir(staticDir)) src.staticDir = staticDir;
    return src;
}
