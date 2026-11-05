/// Reading a site's source tree from disk.
module sitegen.source_;

import std.file;
import std.path : buildPath;
import std.algorithm.searching : endsWith;

/// The raw text of every input of a site, keyed by file name.
///
/// Building this by hand makes it possible to generate a site entirely in
/// memory (the unit tests do).
struct SiteSource
{
    string siteToml; /// contents of `site.toml`
    string[string] posts; /// `content/posts/<name>.md` contents by file name
    string[string] pages; /// `content/pages/<name>.md` contents by file name
    string[string] templates; /// `templates/<name>.html` contents by file name
}

private string readText(string path)
{
    return cast(string) read(path);
}

private string[string] readDirectory(string dir, string suffix)
{
    string[string] result;
    if (!exists(dir) || !isDir(dir))
        return result;
    foreach (entry; dirEntries(dir, SpanMode.shallow))
    {
        string name = entry.name[dir.length + 1 .. $];
        if (entry.isFile && name.endsWith(suffix))
            result[name] = readText(entry.name);
    }
    return result;
}

/// Read `site.toml`, the content files and the templates under `inputDir`.
SiteSource readSiteSource(string inputDir)
{
    SiteSource src;
    src.siteToml = readText(buildPath(inputDir, "site.toml"));
    src.posts = readDirectory(buildPath(inputDir, "content", "posts"), ".md");
    src.pages = readDirectory(buildPath(inputDir, "content", "pages"), ".md");
    src.templates = readDirectory(buildPath(inputDir, "templates"), ".html");
    return src;
}
