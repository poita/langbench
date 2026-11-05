/// The Atom feed and the sitemap.
module sitegen.feed;

import sitegen.model;
import sitegen.xml;
import std.array : Appender, appender;
import std.conv : to;

/// Render `feed.xml`: an Atom 1.0 feed of the newest `posts_per_page` posts.
string renderFeed(const Site site)
{
    auto o = appender!(char[])();
    immutable count = site.posts.length < cast(size_t) site.postsPerPage
        ? site.posts.length : cast(size_t) site.postsPerPage;
    string updated = site.posts.length ? site.posts[0].date ~ "T00:00:00Z" : "1970-01-01T00:00:00Z";
    o.put("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    o.put("<feed xmlns=\"http://www.w3.org/2005/Atom\">\n");
    o.put("  <title>");
    putXmlText(o, site.title);
    o.put("</title>\n  <id>");
    putXmlText(o, site.baseUrl ~ "/");
    o.put("</id>\n  <updated>");
    o.put(updated);
    o.put("</updated>\n  <link href=\"");
    putXmlAttr(o, site.baseUrl ~ "/");
    o.put("\" rel=\"alternate\"/>\n  <link href=\"");
    putXmlAttr(o, site.baseUrl ~ "/feed.xml");
    o.put("\" rel=\"self\"/>\n  <author>\n    <name>");
    putXmlText(o, site.author);
    o.put("</name>\n  </author>\n");
    foreach (ref post; site.posts[0 .. count])
    {
        string permalink = site.baseUrl ~ post.url;
        o.put("  <entry>\n    <title>");
        putXmlText(o, post.title);
        o.put("</title>\n    <id>");
        putXmlText(o, permalink);
        o.put("</id>\n    <updated>");
        o.put(post.date);
        o.put("T00:00:00Z</updated>\n    <link href=\"");
        putXmlAttr(o, permalink);
        o.put("\" rel=\"alternate\"/>\n    <content type=\"html\">");
        putXmlText(o, post.content);
        o.put("</content>\n  </entry>\n");
    }
    o.put("</feed>\n");
    return o.data.idup;
}

/// The URL of index page `number` (1-based): `/` or `/page/N/`.
string indexPageUrl(size_t number) pure nothrow @safe
{
    return number == 1 ? "/" : "/page/" ~ number.to!string ~ "/";
}

/// Render `sitemap.xml`.
string renderSitemap(const Site site)
{
    auto o = appender!(char[])();
    void url(string loc, string lastmod = null)
    {
        o.put("  <url>\n    <loc>");
        putXmlText(o, loc);
        o.put("</loc>\n");
        if (lastmod !is null)
        {
            o.put("    <lastmod>");
            o.put(lastmod);
            o.put("</lastmod>\n");
        }
        o.put("  </url>\n");
    }

    o.put("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    o.put("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");
    foreach (n; 1 .. site.indexPageCount + 1)
        url(site.baseUrl ~ indexPageUrl(n));
    foreach (ref post; site.posts)
        url(site.baseUrl ~ post.url, post.date);
    foreach (ref page; site.pages)
        url(site.baseUrl ~ page.url);
    url(site.baseUrl ~ "/tags/");
    foreach (ref tag; site.tags)
        url(site.baseUrl ~ tag.url);
    o.put("</urlset>\n");
    return o.data.idup;
}
