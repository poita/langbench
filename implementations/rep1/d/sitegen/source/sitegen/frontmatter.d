/// Splitting content files into TOML front matter and a Markdown body.
module sitegen.frontmatter;

import sitegen.toml;

/// A content file split into its metadata and body.
struct FrontMatter
{
    TomlDocument meta; /// the parsed front matter
    string body_; /// everything after the closing `+++` line
}

/// Thrown when a content file does not start with valid front matter.
class FrontMatterException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// Split `text` at its `+++` delimiter lines and parse the front matter.
///
/// The text must start with `+++\n`; the front matter ends at the first later
/// line that is exactly `+++`.
FrontMatter splitFrontMatter(string text)
{
    enum opening = "+++\n";
    if (text.length < opening.length || text[0 .. opening.length] != opening)
        throw new FrontMatterException("content file does not start with '+++'");
    size_t pos = opening.length;
    while (pos <= text.length)
    {
        size_t e = pos;
        while (e < text.length && text[e] != '\n')
            ++e;
        if (text[pos .. e] == "+++")
        {
            FrontMatter fm;
            fm.meta = parseToml(text[opening.length .. pos]);
            fm.body_ = e < text.length ? text[e + 1 .. $] : "";
            return fm;
        }
        if (e >= text.length)
            break;
        pos = e + 1;
    }
    throw new FrontMatterException("front matter is not closed");
}
