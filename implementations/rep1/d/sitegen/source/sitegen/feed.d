/**
 * The Atom feed and the XML sitemap.
 */
module sitegen.feed;

import std.array : Appender, appender;
import sitegen.context : indexUrl;
import sitegen.model;

/// Escapes `&`, `<` and `>` for XML text.
string xmlText(string s) pure
{
    auto o = appender!string();
    putXmlText(o, s);
    return o.data;
}

/// Escapes `&`, `<`, `>` and `"` for an XML attribute value.
string xmlAttr(string s) pure
{
    auto o = appender!string();
    foreach (char c; s)
    {
        switch (c)
        {
            case '&': o.put("&amp;"); break;
            case '<': o.put("&lt;"); break;
            case '>': o.put("&gt;"); break;
            case '"': o.put("&quot;"); break;
            default: o.put(c);
        }
    }
    return o.data;
}

private void putXmlText(ref Appender!string o, string s) pure
{
    size_t start = 0;
    foreach (i, char c; s)
    {
        string rep;
        switch (c)
        {
            case '&': rep = "&amp;"; break;
            case '<': rep = "&lt;"; break;
            case '>': rep = "&gt;"; break;
            default: continue;
        }
        o.put(s[start .. i]);
        o.put(rep);
        start = i + 1;
    }
    o.put(s[start .. $]);
}

/// Renders `feed.xml`: an Atom feed of the newest `posts_per_page` posts.
string renderFeed(const Site site)
{
    const base = site.config.baseUrl;
    auto o = appender!string();
    o.put("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    o.put("<feed xmlns=\"http://www.w3.org/2005/Atom\">\n");
    o.put("  <title>");
    putXmlText(o, site.config.title);
    o.put("</title>\n  <id>");
    putXmlText(o, base ~ "/");
    o.put("</id>\n  <updated>");
    o.put(site.posts.length ? site.posts[0].date ~ "T00:00:00Z" : "1970-01-01T00:00:00Z");
    o.put("</updated>\n  <link href=\"");
    o.put(xmlAttr(base ~ "/"));
    o.put("\" rel=\"alternate\"/>\n  <link href=\"");
    o.put(xmlAttr(base ~ "/feed.xml"));
    o.put("\" rel=\"self\"/>\n  <author>\n    <name>");
    putXmlText(o, site.config.author);
    o.put("</name>\n  </author>\n");
    size_t count = site.posts.length;
    if (count > site.config.postsPerPage) count = site.config.postsPerPage;
    foreach (p; site.posts[0 .. count])
    {
        const permalink = base ~ p.url;
        o.put("  <entry>\n    <title>");
        putXmlText(o, p.title);
        o.put("</title>\n    <id>");
        putXmlText(o, permalink);
        o.put("</id>\n    <updated>");
        o.put(p.date);
        o.put("T00:00:00Z</updated>\n    <link href=\"");
        o.put(xmlAttr(permalink));
        o.put("\" rel=\"alternate\"/>\n    <content type=\"html\">");
        putXmlText(o, p.content);
        o.put("</content>\n  </entry>\n");
    }
    o.put("</feed>\n");
    return o.data;
}

/// Renders `sitemap.xml`.
string renderSitemap(const Site site)
{
    const base = site.config.baseUrl;
    auto o = appender!string();
    o.put("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    o.put("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");

    void entry(string url, string lastmod = null)
    {
        o.put("  <url>\n    <loc>");
        putXmlText(o, base ~ url);
        o.put("</loc>\n");
        if (lastmod !is null)
        {
            o.put("    <lastmod>");
            o.put(lastmod);
            o.put("</lastmod>\n");
        }
        o.put("  </url>\n");
    }

    foreach (n; 1 .. site.totalPages + 1) entry(indexUrl(n));
    foreach (p; site.posts) entry(p.url, p.date);
    foreach (p; site.pages) entry(p.url);
    entry("/tags/");
    foreach (t; site.tags) entry(t.url);
    o.put("</urlset>\n");
    return o.data;
}

unittest
{
    assert(xmlText(`a&b<c>"d'`) == `a&amp;b&lt;c&gt;"d'`);
    assert(xmlAttr(`a&b<c>"d'`) == `a&amp;b&lt;c&gt;&quot;d'`);
}
