/// End-to-end tests: generate whole sites in memory.
module tests.render_test;

import sitegen.feed;
import sitegen.model;
import sitegen.render;
import sitegen.source_;

private string find(const OutputFile[] files, string path)
{
    foreach (f; files)
        if (f.path == path)
            return f.content;
    assert(false, "no output file " ~ path);
}

/// The worked example of the specification.
private SiteSource pond()
{
    SiteSource s;
    s.siteToml = "title = \"Pond Notes\"\nbase_url = \"https://pond.example\"\nauthor = \"R. Duck\"\nposts_per_page = 1\n";
    s.posts["hello-world.md"] = "+++\ntitle = \"Hello, world\"\ndate = \"2024-01-10\"\ntags = [\"Meta\"]\n+++\nThe **first** post.\n\nMore text.\n";
    s.posts["on-ducks.md"] = "+++\ntitle = \"On Ducks\"\ndate = \"2024-02-01\"\ntags = [\"Birds\", \"Meta\"]\nslug = \"ducks\"\n+++\nDucks are *fine*.\n";
    s.pages["about.md"] = "+++\ntitle = \"About\"\n+++\n# About\n\nNothing here.\n";
    s.templates["base.html"] = "<!doctype html>\n<title>{% block title %}{{ site.title }}{% endblock %}</title>\n{% block body %}{% endblock %}\n";
    s.templates["index.html"] = "{% extends \"base.html\" %}\n{% block body %}{% for post in posts %}<h2><a href=\"{{ post.url }}\">{{ post.title }}</a></h2>\n{{ post.excerpt }}{% endfor %}<p>page {{ pagination.number }} of {{ pagination.total_pages }}</p>\n{% if pagination.has_next %}<a href=\"{{ pagination.next_url }}\">older</a>{% endif %}{% endblock %}\n";
    s.templates["post.html"] = "{% extends \"base.html\" %}\n{% block title %}{{ post.title }} · {{ site.title }}{% endblock %}\n{% block body %}<article>\n{{ post.content }}</article>\n<p>{{ post.date_long }}{% for t in post.tags %} <a href=\"{{ t.url }}\">{{ t.name }}</a>{% endfor %}</p>\n{% if post.older %}<a href=\"{{ post.older.url }}\">{{ post.older.title }}</a>{% endif %}{% endblock %}\n";
    s.templates["page.html"] = "{% extends \"base.html\" %}\n{% block title %}{{ page.title }}{% endblock %}\n{% block body %}{{ page.content }}{% endblock %}\n";
    s.templates["tag.html"] = "{% extends \"base.html\" %}\n{% block body %}<h1>{{ tag.name }} ({{ tag.post_count }})</h1>\n<ul>{% for post in posts %}<li>{{ post.title }}</li>{% endfor %}</ul>{% endblock %}\n";
    s.templates["tags.html"] = "{% extends \"base.html\" %}\n{% block body %}<ul>{% for t in tags %}<li><a href=\"{{ t.url }}\">{{ t.name }}</a> {{ t.post_count }}</li>{% endfor %}</ul>{% endblock %}\n";
    return s;
}

unittest // the worked example: files and pages
{
    auto src = pond();
    auto files = renderSite(src);
    string[] paths;
    foreach (f; files)
        paths ~= f.path;
    import std.conv : to;

    assert(paths == ["index.html", "page/2/index.html", "posts/ducks/index.html",
            "posts/hello-world/index.html", "about/index.html", "tags/index.html",
            "tags/birds/index.html", "tags/meta/index.html", "feed.xml", "sitemap.xml"], paths.to!string);

    assert(find(files, "index.html") == "<!doctype html>\n<title>Pond Notes</title>\n"
            ~ "<h2><a href=\"/posts/ducks/\">On Ducks</a></h2>\n<p>Ducks are <em>fine</em>.</p>\n"
            ~ "<p>page 1 of 2</p>\n<a href=\"/page/2/\">older</a>");
    assert(find(files, "posts/ducks/index.html") == "<!doctype html>\n<title>On Ducks · Pond Notes</title>\n"
            ~ "<article>\n<p>Ducks are <em>fine</em>.</p>\n</article>\n"
            ~ "<p>February 1, 2024 <a href=\"/tags/birds/\">Birds</a> <a href=\"/tags/meta/\">Meta</a></p>\n"
            ~ "<a href=\"/posts/hello-world/\">Hello, world</a>");
    assert(find(files, "tags/index.html") == "<!doctype html>\n<title>Pond Notes</title>\n"
            ~ "<ul><li><a href=\"/tags/birds/\">Birds</a> 1</li><li><a href=\"/tags/meta/\">Meta</a> 2</li></ul>");
}

unittest // the worked example: feed and sitemap
{
    auto src = pond();
    auto files = renderSite(src);
    assert(find(files, "feed.xml") == `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Pond Notes</title>
  <id>https://pond.example/</id>
  <updated>2024-02-01T00:00:00Z</updated>
  <link href="https://pond.example/" rel="alternate"/>
  <link href="https://pond.example/feed.xml" rel="self"/>
  <author>
    <name>R. Duck</name>
  </author>
  <entry>
    <title>On Ducks</title>
    <id>https://pond.example/posts/ducks/</id>
    <updated>2024-02-01T00:00:00Z</updated>
    <link href="https://pond.example/posts/ducks/" rel="alternate"/>
    <content type="html">&lt;p&gt;Ducks are &lt;em&gt;fine&lt;/em&gt;.&lt;/p&gt;
</content>
  </entry>
</feed>
`);
    assert(find(files, "sitemap.xml") == `<?xml version="1.0" encoding="utf-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://pond.example/</loc>
  </url>
  <url>
    <loc>https://pond.example/page/2/</loc>
  </url>
  <url>
    <loc>https://pond.example/posts/ducks/</loc>
    <lastmod>2024-02-01</lastmod>
  </url>
  <url>
    <loc>https://pond.example/posts/hello-world/</loc>
    <lastmod>2024-01-10</lastmod>
  </url>
  <url>
    <loc>https://pond.example/about/</loc>
  </url>
  <url>
    <loc>https://pond.example/tags/</loc>
  </url>
  <url>
    <loc>https://pond.example/tags/birds/</loc>
  </url>
  <url>
    <loc>https://pond.example/tags/meta/</loc>
  </url>
</urlset>
`);
}

unittest // a site without posts still has one index page and an empty feed
{
    SiteSource s = pond();
    s.posts.clear();
    auto files = renderSite(s);
    assert(find(files, "index.html").length > 0);
    foreach (f; files)
        assert(f.path != "page/2/index.html");
    auto feed = find(files, "feed.xml");
    assert(feed == `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Pond Notes</title>
  <id>https://pond.example/</id>
  <updated>1970-01-01T00:00:00Z</updated>
  <link href="https://pond.example/" rel="alternate"/>
  <link href="https://pond.example/feed.xml" rel="self"/>
  <author>
    <name>R. Duck</name>
  </author>
</feed>
`);
}

unittest // feed escaping
{
    SiteSource s = pond();
    s.siteToml = "title = \"A & B <c>\"\nbase_url = \"https://x.org/a\\\"b\"\nauthor = \"O'Neil\"\nposts_per_page = 5\n";
    auto feed = find(renderSite(s), "feed.xml");
    import std.algorithm.searching : canFind;

    assert(feed.canFind("<title>A &amp; B &lt;c&gt;</title>"));
    assert(feed.canFind("<link href=\"https://x.org/a&quot;b/\" rel=\"alternate\"/>"));
    assert(feed.canFind("<name>O'Neil</name>"));
}

unittest // template errors are reported with the page being rendered
{
    import std.exception : assertThrown;

    SiteSource s = pond();
    s.templates["tags.html"] = "{{ nonexistent }}";
    assertThrown!RenderException(renderSite(s));
}
