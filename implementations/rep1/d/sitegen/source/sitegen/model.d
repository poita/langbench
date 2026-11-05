/// The content model of a site: posts, pages and tags, with their ordering,
/// slugs, URLs and rendered HTML.
module sitegen.model;

import sitegen.frontmatter;
import sitegen.markdown : markdownToHtml;
import sitegen.source_;
import sitegen.toml;
import std.algorithm.sorting : sort;
import std.array : appender;

/// A published post.
struct Post
{
    string title;
    string slug;
    string date; /// `YYYY-MM-DD`
    string[] tags; /// de-duplicated tag names in front-matter order
    string content; /// body as HTML
    string excerpt; /// HTML of the body's first block

    string url() const pure nothrow @safe
    {
        return "/posts/" ~ slug ~ "/";
    }
}

/// A published page.
struct Page
{
    string title;
    string slug;
    string content;

    string url() const pure nothrow @safe
    {
        return "/" ~ slug ~ "/";
    }
}

/// A tag that at least one published post carries.
struct Tag
{
    string name;
    string slug;
    size_t[] posts; /// indices into `Site.posts`, in canonical order

    string url() const pure nothrow @safe
    {
        return "/tags/" ~ slug ~ "/";
    }
}

/// The whole content model.
final class Site
{
    TomlDocument config; /// the parsed `site.toml`, in file order
    string title;
    string baseUrl; /// without a trailing `/`
    string author;
    long postsPerPage;
    Post[] posts; /// published posts, newest first
    Page[] pages; /// published pages, by slug
    Tag[] tags; /// existing tags, by slug
    /// For every post, the indices into `tags` of its tags (same order as `Post.tags`).
    size_t[][] postTags;

    /// Number of index pages: `max(1, ceil(posts / postsPerPage))`.
    size_t indexPageCount() const pure nothrow @safe
    {
        immutable p = cast(size_t) postsPerPage;
        immutable n = posts.length;
        immutable pages = (n + p - 1) / p;
        return pages < 1 ? 1 : pages;
    }
}

/// The slug of a tag name: lower-case ASCII letters and digits, with every
/// other run of characters collapsed to a single `-` and no leading or
/// trailing `-`.
string tagSlug(string name) pure nothrow @safe
{
    auto o = appender!(char[])();
    bool pendingDash = false;
    foreach (char c; name)
    {
        if (c >= 'A' && c <= 'Z')
            c += 32;
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
        {
            if (pendingDash && o.data.length)
                o.put('-');
            pendingDash = false;
            o.put(c);
        }
        else
            pendingDash = true;
    }
    return o.data.idup;
}

private immutable monthNames = [
    "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December"
];

/// `2024-03-05` -> `March 5, 2024`.
string longDate(string date) pure @safe
{
    import std.conv : to;

    if (date.length != 10)
        return date;
    immutable month = date[5 .. 7].to!int;
    immutable day = date[8 .. 10].to!int;
    return monthNames[month - 1] ~ " " ~ day.to!string ~ ", " ~ date[0 .. 4];
}

/// The Markdown source of a body's first block: skip leading blank lines, then
/// take the following run of non-blank lines joined with LF.
string firstBlock(string body_) pure nothrow @safe
{
    static bool isBlankLine(string l) pure nothrow @safe @nogc
    {
        foreach (c; l)
            if (c != ' ' && c != '\t')
                return false;
        return true;
    }

    size_t pos = 0;
    // skip blank lines
    while (pos < body_.length)
    {
        size_t e = pos;
        while (e < body_.length && body_[e] != '\n')
            ++e;
        if (!isBlankLine(body_[pos .. e]))
            break;
        pos = e + 1;
    }
    if (pos >= body_.length)
        return "";
    size_t end = pos;
    size_t cursor = pos;
    while (cursor < body_.length)
    {
        size_t e = cursor;
        while (e < body_.length && body_[e] != '\n')
            ++e;
        if (isBlankLine(body_[cursor .. e]))
            break;
        end = e;
        cursor = e + 1;
    }
    return body_[pos .. end];
}

private string defaultSlug(string fileName) pure nothrow @safe
{
    return fileName[0 .. $ - 3]; // strip ".md"
}

/// Build the content model from the raw sources.
Site buildSite(const ref SiteSource src)
{
    auto site = new Site;
    site.config = parseToml(src.siteToml);
    site.title = site.config.getString("title");
    site.baseUrl = site.config.getString("base_url");
    site.author = site.config.getString("author");
    site.postsPerPage = site.config.getInteger("posts_per_page", 10);
    if (site.postsPerPage < 1)
        site.postsPerPage = 1;

    foreach (name, text; src.posts)
    {
        auto fm = splitFrontMatter(text);
        if (fm.meta.getBool("draft"))
            continue;
        Post p;
        p.title = fm.meta.getString("title");
        p.date = fm.meta.getString("date");
        p.slug = fm.meta.getString("slug", defaultSlug(name));
        foreach (t; fm.meta.getArray("tags"))
        {
            bool dup = false;
            foreach (existing; p.tags)
                if (existing == t)
                    dup = true;
            if (!dup)
                p.tags ~= t;
        }
        p.content = markdownToHtml(fm.body_);
        p.excerpt = markdownToHtml(firstBlock(fm.body_));
        site.posts ~= p;
    }
    site.posts.sort!((a, b) => a.date != b.date ? a.date > b.date : a.slug < b.slug);

    foreach (name, text; src.pages)
    {
        auto fm = splitFrontMatter(text);
        if (fm.meta.getBool("draft"))
            continue;
        Page p;
        p.title = fm.meta.getString("title");
        p.slug = fm.meta.getString("slug", defaultSlug(name));
        p.content = markdownToHtml(fm.body_);
        site.pages ~= p;
    }
    site.pages.sort!((a, b) => a.slug < b.slug);

    // collect tags in one pass over the posts in canonical order
    size_t[string] byName;
    Tag[] collected;
    site.postTags = new size_t[][site.posts.length];
    foreach (i, ref post; site.posts)
    {
        foreach (name; post.tags)
        {
            size_t idx;
            if (auto p = name in byName)
                idx = *p;
            else
            {
                idx = collected.length;
                byName[name] = idx;
                collected ~= Tag(name, tagSlug(name));
            }
            collected[idx].posts ~= i;
        }
    }
    // order the tags by slug and remap indices
    auto order = new size_t[collected.length];
    foreach (k, ref o; order)
        o = k;
    order.sort!((a, b) => collected[a].slug < collected[b].slug);
    auto remap = new size_t[collected.length];
    foreach (newIdx, oldIdx; order)
    {
        remap[oldIdx] = newIdx;
        site.tags ~= collected[oldIdx];
    }
    foreach (i, ref post; site.posts)
        foreach (name; post.tags)
            site.postTags[i] ~= remap[byName[name]];
    return site;
}
