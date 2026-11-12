/**
 * The content model: posts, pages and tags, with their ordering, slugs,
 * dates, excerpts and rendered HTML.
 */
module sitegen.model;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.array : Appender, appender;
import sitegen.frontmatter;
import sitegen.markdown : markdownToHtml;
import sitegen.source;
import sitegen.toml;

/// The settings of `site.toml`.
struct SiteConfig
{
    /// The whole parsed document, in file order.
    TomlDocument doc;
    string title;
    /// The base URL, without a trailing `/`.
    string baseUrl;
    string author;
    /// How many posts one index page shows; at least 1.
    size_t postsPerPage;
}

/// A published post.
final class Post
{
    string title;
    string slug;
    /// `YYYY-MM-DD`.
    string date;
    /// The post's tag names, without repeats, in front-matter order.
    string[] tags;
    /// The HTML of the whole body.
    string content;
    /// The HTML of the body's first block.
    string excerpt;

    /// `/posts/<slug>/`
    string url() const
    {
        return "/posts/" ~ slug ~ "/";
    }
}

/// A published page.
final class Page
{
    string title;
    string slug;
    /// The HTML of the body.
    string content;

    /// `/<slug>/`
    string url() const
    {
        return "/" ~ slug ~ "/";
    }
}

/// A tag that at least one published post carries.
final class Tag
{
    string name;
    string slug;
    /// The tag's posts, in canonical order.
    Post[] posts;

    /// `/tags/<slug>/`
    string url() const
    {
        return "/tags/" ~ slug ~ "/";
    }
}

/// A whole site, ready to be rendered.
final class Site
{
    SiteConfig config;
    /// The published posts in canonical order: newest first, ties by slug.
    Post[] posts;
    /// The published pages by slug.
    Page[] pages;
    /// The existing tags by slug.
    Tag[] tags;

    /// The number of index pages: `max(1, ceil(posts / postsPerPage))`.
    size_t totalPages() const
    {
        const n = posts.length;
        const pp = config.postsPerPage;
        const pages = (n + pp - 1) / pp;
        return pages < 1 ? 1 : pages;
    }
}

/**
 * The slug of a tag name: ASCII letters lower-cased, every other character
 * other than `a`-`z` and `0`-`9` replaced by `-`, runs of `-` collapsed and
 * leading and trailing `-` removed.
 */
string tagSlug(string name) pure
{
    auto o = appender!string();
    bool pendingDash = false;
    foreach (char c; name)
    {
        if (c >= 'A' && c <= 'Z') c += 32;
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
        {
            if (pendingDash && o.data.length) o.put('-');
            pendingDash = false;
            o.put(c);
        }
        else
            pendingDash = true;
    }
    return o.data;
}

private immutable string[12] monthNames = ["January", "February", "March", "April", "May",
    "June", "July", "August", "September", "October", "November", "December"];

/// Formats `YYYY-MM-DD` as `<Month> <D>, <YYYY>`.
string longDate(string date) pure
{
    const month = (date[5 .. 7]).to!int;
    const day = (date[8 .. 10]).to!int;
    return monthNames[month - 1] ~ " " ~ day.to!string ~ ", " ~ date[0 .. 4];
}

/**
 * The first block of a Markdown body: skips leading blank lines and takes the
 * following maximal run of non-blank lines, joined with LF.  The rule is
 * purely textual.
 */
string firstBlock(string body_) pure
{
    size_t pos = 0;
    // Skip blank lines.
    while (pos < body_.length)
    {
        size_t eol = pos;
        bool blank = true;
        while (eol < body_.length && body_[eol] != '\n')
        {
            if (body_[eol] != ' ' && body_[eol] != '\t') blank = false;
            eol++;
        }
        if (!blank) break;
        pos = eol + 1;
    }
    if (pos >= body_.length) return "";
    const start = pos;
    size_t end = pos;
    while (pos < body_.length)
    {
        size_t eol = pos;
        bool blank = true;
        while (eol < body_.length && body_[eol] != '\n')
        {
            if (body_[eol] != ' ' && body_[eol] != '\t') blank = false;
            eol++;
        }
        if (blank) break;
        end = eol;
        pos = eol + 1;
    }
    return body_[start .. end];
}

private string requireString(const TomlDocument doc, string key, string what)
{
    TomlValue v;
    if (!doc.get(key, v) || v.kind != TomlKind.string_)
        throw new TomlException(what ~ ": '" ~ key ~ "' must be a string", 0);
    return v.str;
}

private bool isDraft(const TomlDocument doc)
{
    TomlValue v;
    return doc.get("draft", v) && v.kind == TomlKind.boolean && v.boolean;
}

private string slugOf(const TomlDocument doc, string fileName)
{
    TomlValue v;
    if (doc.get("slug", v) && v.kind == TomlKind.string_) return v.str;
    return fileName[0 .. $ - 3]; // remove ".md"
}

/// Parses `site.toml`.
SiteConfig parseConfig(string text)
{
    SiteConfig c;
    c.doc = parseToml(text);
    c.title = requireString(c.doc, "title", "site.toml");
    c.baseUrl = requireString(c.doc, "base_url", "site.toml");
    c.author = requireString(c.doc, "author", "site.toml");
    const ppp = c.doc["posts_per_page"];
    if (ppp.kind != TomlKind.integer || ppp.integer < 1)
        throw new TomlException("site.toml: 'posts_per_page' must be an integer >= 1", 0);
    c.postsPerPage = cast(size_t) ppp.integer;
    return c;
}

/**
 * Builds the model of a site from its source.
 *
 * Each body and each excerpt is converted to HTML exactly once.  Tags are
 * collected in O(K + T log T) for K (post, tag) pairs and T tags.
 *
 * Throws: `TomlException` for malformed configuration or front matter.
 */
Site buildSite(const SiteSource src)
{
    auto site = new Site;
    site.config = parseConfig(src.config);

    foreach (ref f; src.posts)
    {
        auto fm = splitFrontMatter(f.text);
        if (isDraft(fm.meta)) continue;
        auto p = new Post;
        p.title = requireString(fm.meta, "title", f.name);
        p.date = requireString(fm.meta, "date", f.name);
        p.slug = slugOf(fm.meta, f.name);
        TomlValue tv;
        if (fm.meta.get("tags", tv) && tv.kind == TomlKind.array)
        {
            bool[string] seen;
            foreach (t; tv.array)
            {
                if (t in seen) continue;
                seen[t] = true;
                p.tags ~= t;
            }
        }
        p.content = markdownToHtml(fm.body_);
        p.excerpt = markdownToHtml(firstBlock(fm.body_));
        site.posts ~= p;
    }
    site.posts.sort!((a, b) => a.date != b.date ? a.date > b.date : a.slug < b.slug);

    foreach (ref f; src.pages)
    {
        auto fm = splitFrontMatter(f.text);
        if (isDraft(fm.meta)) continue;
        auto p = new Page;
        p.title = requireString(fm.meta, "title", f.name);
        p.slug = slugOf(fm.meta, f.name);
        p.content = markdownToHtml(fm.body_);
        site.pages ~= p;
    }
    site.pages.sort!((a, b) => a.slug < b.slug);

    // Collect the tags: one pass over the posts in canonical order, so each
    // tag's post list is already in canonical order.
    Tag[string] byName;
    foreach (p; site.posts)
    {
        foreach (name; p.tags)
        {
            auto t = name in byName;
            if (t is null)
            {
                auto nt = new Tag;
                nt.name = name;
                nt.slug = tagSlug(name);
                byName[name] = nt;
                t = name in byName;
            }
            t.posts ~= p;
        }
    }
    site.tags = byName.values;
    site.tags.sort!((a, b) => a.slug < b.slug);
    return site;
}

unittest
{
    assert(tagSlug("Web Development") == "web-development");
    assert(tagSlug("C++") == "c");
    assert(tagSlug("Rust 2024") == "rust-2024");
    assert(tagSlug("  --a__b--  ") == "a-b");
    assert(tagSlug("é") == "");
}

unittest
{
    assert(longDate("2024-03-05") == "March 5, 2024");
    assert(longDate("1999-12-25") == "December 25, 1999");
}

unittest
{
    assert(firstBlock("\n  \nFirst\nstill\n\nSecond") == "First\nstill");
    assert(firstBlock("# Title\n\ntext") == "# Title");
    assert(firstBlock("   \n\t\n") == "");
    assert(firstBlock("```\ncode\n\nmore\n```") == "```\ncode");
    assert(firstBlock("one") == "one");
}

unittest
{
    SiteSource src;
    src.config = "title = \"T\"\nbase_url = \"https://x\"\nauthor = \"A\"\nposts_per_page = 2\n";
    src.posts = [
        SourceFile("b.md", "+++\ntitle = \"B\"\ndate = \"2024-01-01\"\ntags = [\"X y\", \"X y\", \"a\"]\n+++\nbody b"),
        SourceFile("a.md", "+++\ntitle = \"A\"\ndate = \"2024-01-01\"\ntags = [\"a\"]\n+++\nbody a"),
        SourceFile("c.md", "+++\ntitle = \"C\"\ndate = \"2024-02-01\"\ndraft = true\ntags = [\"zzz\"]\n+++\n"),
        SourceFile("d.md", "+++\ntitle = \"D\"\ndate = \"2023-05-05\"\nslug = \"dd\"\n+++\nbody d"),
    ];
    auto site = buildSite(src);
    assert(site.posts.length == 3);
    assert(site.posts[0].slug == "a" && site.posts[1].slug == "b" && site.posts[2].slug == "dd");
    assert(site.posts[1].tags == ["X y", "a"]);
    assert(site.tags.length == 2);
    assert(site.tags[0].name == "a" && site.tags[0].posts.length == 2);
    assert(site.tags[1].slug == "x-y");
    assert(site.totalPages == 2);
}
