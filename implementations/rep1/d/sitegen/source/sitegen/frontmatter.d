/**
 * Splitting a content file into its TOML front matter and its Markdown body.
 */
module sitegen.frontmatter;

import sitegen.toml;

/// A content file split into its parts.
struct FrontMatter
{
    /// The parsed front matter.
    TomlDocument meta;
    /// Everything after the closing `+++` line, verbatim.
    string body_;
}

/**
 * Splits `text` into front matter and body.
 *
 * The file must begin with the line `+++`; the front matter ends at the next
 * line that is exactly `+++`.
 *
 * Throws: `TomlException` if the delimiters or the front matter are malformed.
 */
FrontMatter splitFrontMatter(string text)
{
    enum opening = "+++\n";
    if (text.length < opening.length || text[0 .. opening.length] != opening)
        throw new TomlException("content file does not start with '+++'", 1);
    size_t pos = opening.length;
    while (pos <= text.length)
    {
        size_t eol = pos;
        while (eol < text.length && text[eol] != '\n') eol++;
        if (text[pos .. eol] == "+++")
        {
            FrontMatter fm;
            fm.meta = parseToml(text[opening.length .. pos]);
            fm.body_ = eol < text.length ? text[eol + 1 .. $] : "";
            return fm;
        }
        if (eol >= text.length) break;
        pos = eol + 1;
    }
    throw new TomlException("front matter is not closed", 1);
}

unittest
{
    auto fm = splitFrontMatter("+++\ntitle = \"T\"\nnote = \"+++ inside\"\n+++\nBody\n+++\nmore\n");
    assert(fm.meta["title"].str == "T");
    assert(fm.meta["note"].str == "+++ inside");
    assert(fm.body_ == "Body\n+++\nmore\n");
}

unittest
{
    assert(splitFrontMatter("+++\ntitle = \"T\"\n+++").body_ == "");
    assert(splitFrontMatter("+++\n+++\n").body_ == "");
    assert(splitFrontMatter("+++\ntitle = \"T\"\n+++\n\n\nx").body_ == "\n\nx");
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!TomlException(splitFrontMatter("title = 1\n"));
    assertThrown!TomlException(splitFrontMatter("+++\ntitle = \"T\"\n"));
}
