/**
 * Building the template values of a site: the `site`, `tags`, `pages`,
 * `posts`, `tag` and `pagination` variables.
 *
 * Post, page and tag objects and their links are built once and shared by
 * every page that shows them; only each index page's `pagination` is built
 * per page.
 */
module sitegen.context;

import std.array : appender;
import std.conv : to;
import sitegen.model;
import sitegen.templating : Dict, Value;
import sitegen.toml;

/// The URL of index page `number` (1-based).
string indexUrl(size_t number)
{
    return number == 1 ? "/" : "/page/" ~ number.to!string ~ "/";
}

/// Converts a parsed TOML-subset document to a dict, keeping file order.
Dict tomlToDict(const TomlDocument doc)
{
    auto d = new Dict;
    foreach (ref e; doc.entries)
    {
        final switch (e.value.kind)
        {
            case TomlKind.string_:
                d.set(e.key, Value.str(e.value.str));
                break;
            case TomlKind.integer:
                d.set(e.key, Value.integer(e.value.integer));
                break;
            case TomlKind.boolean:
                d.set(e.key, Value.boolean(e.value.boolean));
                break;
            case TomlKind.array:
                d.set(e.key, Value.list(e.value.array));
                break;
        }
    }
    return d;
}

/// The shared template values of a site.
struct SiteValues
{
    /// The `site` variable.
    Value site;
    /// The `tags` variable: a list of tag links.
    Value tagLinks;
    /// The `pages` variable: a list of page links.
    Value pageLinks;
    /// One post object per post, in canonical order.
    Value[] posts;
    /// One page object per page.
    Value[] pages;
    /// One tag object per tag, in tag-list order.
    Value[] tags;
}

private Value postLink(const Site site, const Post p)
{
    auto d = new Dict;
    d.set("title", Value.str(p.title));
    d.set("slug", Value.str(p.slug));
    d.set("url", Value.str(p.url));
    d.set("permalink", Value.str(site.config.baseUrl ~ p.url));
    d.set("date", Value.str(p.date));
    d.set("date_long", Value.str(longDate(p.date)));
    return Value.dict(d);
}

/// Builds the values shared by every page of `site`.
SiteValues buildValues(const Site site)
{
    SiteValues sv;
    const base = site.config.baseUrl;
    sv.site = Value.dict(tomlToDict(site.config.doc));

    // Tag links, shared by the tag list and by every post.
    Value[string] tagLinkByName;
    auto tagLinks = new Value[site.tags.length];
    foreach (i, t; site.tags)
    {
        auto d = new Dict;
        d.set("name", Value.str(t.name));
        d.set("slug", Value.str(t.slug));
        d.set("url", Value.str(t.url));
        d.set("post_count", Value.integer(cast(long) t.posts.length));
        tagLinks[i] = Value.dict(d);
        tagLinkByName[t.name] = tagLinks[i];
    }
    sv.tagLinks = Value.list(tagLinks);

    // Page links and pages.
    auto pageLinks = new Value[site.pages.length];
    sv.pages = new Value[site.pages.length];
    foreach (i, p; site.pages)
    {
        auto l = new Dict;
        l.set("title", Value.str(p.title));
        l.set("slug", Value.str(p.slug));
        l.set("url", Value.str(p.url));
        pageLinks[i] = Value.dict(l);

        auto d = new Dict;
        d.set("title", Value.str(p.title));
        d.set("slug", Value.str(p.slug));
        d.set("url", Value.str(p.url));
        d.set("permalink", Value.str(base ~ p.url));
        d.set("content", Value.str(p.content));
        sv.pages[i] = Value.dict(d);
    }
    sv.pageLinks = Value.list(pageLinks);

    // Posts, with older/newer links to their neighbours.
    auto links = new Value[site.posts.length];
    foreach (i, p; site.posts) links[i] = postLink(site, p);
    sv.posts = new Value[site.posts.length];
    foreach (i, p; site.posts)
    {
        auto d = new Dict;
        d.set("title", Value.str(p.title));
        d.set("slug", Value.str(p.slug));
        d.set("url", Value.str(p.url));
        d.set("permalink", Value.str(base ~ p.url));
        d.set("date", Value.str(p.date));
        d.set("date_long", Value.str(longDate(p.date)));
        auto ptags = new Value[p.tags.length];
        foreach (j, name; p.tags) ptags[j] = tagLinkByName[name];
        d.set("tags", Value.list(ptags));
        d.set("content", Value.str(p.content));
        d.set("excerpt", Value.str(p.excerpt));
        d.set("older", i + 1 < links.length ? links[i + 1] : Value.none);
        d.set("newer", i > 0 ? links[i - 1] : Value.none);
        sv.posts[i] = Value.dict(d);
    }

    // Tag objects.
    size_t[const(Post)] postIndex;
    foreach (i, p; site.posts) postIndex[p] = i;
    sv.tags = new Value[site.tags.length];
    foreach (i, t; site.tags)
    {
        auto d = new Dict;
        d.set("name", Value.str(t.name));
        d.set("slug", Value.str(t.slug));
        d.set("url", Value.str(t.url));
        d.set("post_count", Value.integer(cast(long) t.posts.length));
        auto ps = new Value[t.posts.length];
        foreach (j, p; t.posts) ps[j] = sv.posts[postIndex[p]];
        d.set("posts", Value.list(ps));
        sv.tags[i] = Value.dict(d);
    }
    return sv;
}

/// Builds the `pagination` variable of index page `number`.
Value paginationValue(const Site site, size_t number)
{
    const total = site.totalPages;
    auto d = new Dict;
    d.set("number", Value.integer(cast(long) number));
    d.set("total_pages", Value.integer(cast(long) total));
    d.set("total_posts", Value.integer(cast(long) site.posts.length));
    d.set("has_prev", Value.boolean(number > 1));
    d.set("has_next", Value.boolean(number < total));
    d.set("prev_url", number > 1 ? Value.str(indexUrl(number - 1)) : Value.none);
    d.set("next_url", number < total ? Value.str(indexUrl(number + 1)) : Value.none);
    auto links = new Value[total];
    foreach (i; 0 .. total)
    {
        auto l = new Dict;
        l.set("number", Value.integer(cast(long)(i + 1)));
        l.set("url", Value.str(indexUrl(i + 1)));
        l.set("current", Value.boolean(i + 1 == number));
        links[i] = Value.dict(l);
    }
    d.set("links", Value.list(links));
    return Value.dict(d);
}
