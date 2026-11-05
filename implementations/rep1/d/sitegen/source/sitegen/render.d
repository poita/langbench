/// Turning the content model into template values and rendering every page.
module sitegen.render;

import sitegen.feed;
import sitegen.model;
import sitegen.source_;
import sitegen.templating;
import sitegen.toml;
import std.algorithm.comparison : min;

/// One generated file: a path relative to the output directory and its text.
struct OutputFile
{
    string path;
    string content;
}

/// The failure to render a template, with the page being generated.
class RenderException : Exception
{
    this(string page, TemplateError cause, string file = __FILE__, size_t line = __LINE__)
    {
        super("rendering " ~ page ~ ": " ~ TemplateError.kindName(cause.kind) ~ " error: "
                ~ cause.msg, file, line);
    }
}

private DictObj makeDict(string[] keys, Value[] values) pure nothrow @safe
{
    auto d = new DictObj;
    d.keys = keys;
    d.values = values;
    return d;
}

private Value tomlToValue(const ref TomlValue v) pure nothrow @safe
{
    final switch (v.kind)
    {
    case TomlKind.string_:
        return Value.of(v.str);
    case TomlKind.integer:
        return Value.of(v.integer);
    case TomlKind.boolean:
        return Value.of(v.boolean);
    case TomlKind.array:
        return Value.ofStrings(v.array);
    }
}

/// Renders the pages of a site with one shared set of template values.
///
/// Every tag link, page link, post, page, tag and pagination link is built once
/// and shared by reference by every page that mentions it.
final class SiteRenderer
{
    private Site site;
    private Engine engine;
    private Value siteValue, tagsValue, pagesValue;
    private Value[] tagLinks, postLinks, postValues, pageValues, tagValues;
    private Value[] pageLinks;

    /// Prepare the template values for `site`, rendering through the templates in `src`.
    this(Site site, const ref SiteSource src)
    {
        this.site = site;
        string[string] templates;
        foreach (name, text; src.templates)
        {
            // a template's source is the file with one trailing LF removed
            templates[name] = text.length && text[$ - 1] == '\n' ? text[0 .. $ - 1] : text;
        }
        engine = new Engine((string name, out string source) {
            if (auto t = name in templates)
            {
                source = *t;
                return true;
            }
            return false;
        });
        buildValues();
    }

    private void buildValues()
    {
        auto siteDict = new DictObj;
        foreach (ref e; site.config.entries)
            siteDict.set(e.key, tomlToValue(e.value));
        siteValue = Value.of(siteDict);

        foreach (ref tag; site.tags)
            tagLinks ~= Value.of(makeDict(["name", "slug", "url", "post_count"],
                    [Value.of(tag.name), Value.of(tag.slug), Value.of(tag.url),
                    Value.of(cast(long) tag.posts.length)]));
        tagsValue = Value.of(tagLinks);

        foreach (ref page; site.pages)
            pageLinks ~= Value.of(makeDict(["title", "slug", "url"],
                    [Value.of(page.title), Value.of(page.slug), Value.of(page.url)]));
        pagesValue = Value.of(pageLinks);

        foreach (ref post; site.posts)
            postLinks ~= Value.of(makeDict(
                    ["title", "slug", "url", "permalink", "date", "date_long"],
                    [Value.of(post.title), Value.of(post.slug), Value.of(post.url),
                    Value.of(site.baseUrl ~ post.url), Value.of(post.date),
                    Value.of(longDate(post.date))]));

        foreach (i, ref post; site.posts)
        {
            auto tagList = new Value[post.tags.length];
            foreach (k, ti; site.postTags[i])
                tagList[k] = tagLinks[ti];
            postValues ~= Value.of(makeDict(
                    ["title", "slug", "url", "permalink", "date", "date_long",
                    "tags", "content", "excerpt", "older", "newer"],
                    [Value.of(post.title), Value.of(post.slug), Value.of(post.url),
                    Value.of(site.baseUrl ~ post.url), Value.of(post.date),
                    Value.of(longDate(post.date)), Value.of(tagList),
                    Value.of(post.content), Value.of(post.excerpt),
                    i + 1 < site.posts.length ? postLinks[i + 1] : Value.none(),
                    i > 0 ? postLinks[i - 1] : Value.none()]));
        }

        foreach (ref page; site.pages)
            pageValues ~= Value.of(makeDict(["title", "slug", "url", "permalink", "content"],
                    [Value.of(page.title), Value.of(page.slug), Value.of(page.url),
                    Value.of(site.baseUrl ~ page.url), Value.of(page.content)]));

        foreach (ref tag; site.tags)
        {
            auto list = new Value[tag.posts.length];
            foreach (k, pi; tag.posts)
                list[k] = postValues[pi];
            tagValues ~= Value.of(makeDict(["name", "slug", "url", "post_count", "posts"],
                    [Value.of(tag.name), Value.of(tag.slug), Value.of(tag.url),
                    Value.of(cast(long) tag.posts.length), Value.of(list)]));
        }
    }

    private string renderTemplate(string page, string templateName, string[] names, Value[] values)
    {
        auto root = new Scope;
        root.set("site", siteValue);
        root.set("tags", tagsValue);
        root.set("pages", pagesValue);
        foreach (k, n; names)
            root.set(n, values[k]);
        try
            return engine.render(templateName, root);
        catch (TemplateError e)
            throw new RenderException(page, e);
    }

    /// Render every page, the feed and the sitemap (not the static files).
    OutputFile[] renderAll()
    {
        OutputFile[] files;
        immutable perPage = cast(size_t) site.postsPerPage;
        immutable totalPages = site.indexPageCount;

        // index pages; link dicts are shared across pages
        Value[] currentLinks, otherLinks;
        foreach (n; 1 .. totalPages + 1)
        {
            Value url = Value.of(indexPageUrl(n));
            otherLinks ~= Value.of(makeDict(["number", "url", "current"],
                    [Value.of(cast(long) n), url, Value.of(false)]));
            currentLinks ~= Value.of(makeDict(["number", "url", "current"],
                    [Value.of(cast(long) n), url, Value.of(true)]));
        }
        foreach (n; 1 .. totalPages + 1)
        {
            immutable from = min((n - 1) * perPage, site.posts.length);
            immutable to = min(n * perPage, site.posts.length);
            auto links = new Value[totalPages];
            foreach (k; 0 .. totalPages)
                links[k] = k + 1 == n ? currentLinks[k] : otherLinks[k];
            auto pagination = makeDict(
                    ["number", "total_pages", "total_posts", "has_prev", "has_next",
                    "prev_url", "next_url", "links"],
                    [Value.of(cast(long) n), Value.of(cast(long) totalPages),
                    Value.of(cast(long) site.posts.length), Value.of(n > 1),
                    Value.of(n < totalPages),
                    n > 1 ? Value.of(indexPageUrl(n - 1)) : Value.none(),
                    n < totalPages ? Value.of(indexPageUrl(n + 1)) : Value.none(),
                    Value.of(links)]);
            string path = n == 1 ? "index.html" : "page/" ~ indexPageUrl(n)[6 .. $] ~ "index.html";
            files ~= OutputFile(path, renderTemplate(path, "index.html", ["posts", "pagination"],
                    [Value.of(postValues[from .. to]), Value.of(pagination)]));
        }

        foreach (i, ref post; site.posts)
        {
            string path = "posts/" ~ post.slug ~ "/index.html";
            files ~= OutputFile(path, renderTemplate(path, "post.html", ["post"], [postValues[i]]));
        }
        foreach (i, ref page; site.pages)
        {
            string path = page.slug ~ "/index.html";
            files ~= OutputFile(path, renderTemplate(path, "page.html", ["page"], [pageValues[i]]));
        }
        files ~= OutputFile("tags/index.html", renderTemplate("tags/index.html", "tags.html", null, null));
        foreach (i, ref tag; site.tags)
        {
            string path = "tags/" ~ tag.slug ~ "/index.html";
            files ~= OutputFile(path, renderTemplate(path, "tag.html", ["tag", "posts"],
                    [tagValues[i], tagValues[i].dict.values[4]]));
        }
        files ~= OutputFile("feed.xml", renderFeed(site));
        files ~= OutputFile("sitemap.xml", renderSitemap(site));
        return files;
    }
}

/// Build the model for `src` and render all of its generated files.
OutputFile[] renderSite(const ref SiteSource src)
{
    auto site = buildSite(src);
    return new SiteRenderer(site, src).renderAll();
}
