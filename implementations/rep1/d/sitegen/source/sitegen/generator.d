/**
 * The generator: renders every page of a site, produces the feed and the
 * sitemap, and writes the output directory.
 */
module sitegen.generator;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.file : DirEntry, SpanMode, copy, dirEntries, isFile, mkdirRecurse, write;
import std.path : buildPath, dirName, relativePath;
import sitegen.context;
import sitegen.feed;
import sitegen.model;
import sitegen.source;
import sitegen.templating;

/// A generated file: its path relative to the output directory (with `/`
/// separators) and its contents.
struct OutputFile
{
    string path;
    string content;
}

/// The templates that are entry points, one per kind of page.
private enum entryTemplates = ["index.html", "post.html", "page.html", "tag.html", "tags.html"];

/// Registers the source's templates in a new engine.  A template's source
/// is the file's text with one trailing LF removed.
TemplateEngine makeEngine(const SiteSource src)
{
    auto engine = new TemplateEngine;
    foreach (ref t; src.templates)
    {
        string text = t.text;
        if (text.length && text[$ - 1] == '\n') text = text[0 .. $ - 1];
        engine.addTemplate(t.name, text);
    }
    return engine;
}

/**
 * Renders every generated file of `site`: all pages, `feed.xml` and
 * `sitemap.xml`.  Static files are not included.
 *
 * Throws: `TemplateException` if a template fails.
 */
OutputFile[] generateFiles(const Site site, TemplateEngine engine)
{
    auto sv = buildValues(site);
    OutputFile[] files;

    Value[string] root;
    root["site"] = sv.site;
    root["tags"] = sv.tagLinks;
    root["pages"] = sv.pageLinks;

    // Index pages.
    const pp = site.config.postsPerPage;
    foreach (n; 1 .. site.totalPages + 1)
    {
        const from = (n - 1) * pp;
        size_t to_ = from + pp;
        if (to_ > sv.posts.length) to_ = sv.posts.length;
        auto slice = from < to_ ? sv.posts[from .. to_] : null;
        auto ctx = root.dup;
        ctx["posts"] = Value.list(slice);
        ctx["pagination"] = paginationValue(site, n);
        files ~= OutputFile(n == 1 ? "index.html" : "page/" ~ n.to!string ~ "/index.html",
            engine.render("index.html", ctx));
    }

    foreach (i, p; site.posts)
    {
        auto ctx = root.dup;
        ctx["post"] = sv.posts[i];
        files ~= OutputFile("posts/" ~ p.slug ~ "/index.html", engine.render("post.html", ctx));
    }

    foreach (i, p; site.pages)
    {
        auto ctx = root.dup;
        ctx["page"] = sv.pages[i];
        files ~= OutputFile(p.slug ~ "/index.html", engine.render("page.html", ctx));
    }

    files ~= OutputFile("tags/index.html", engine.render("tags.html", root));

    foreach (i, t; site.tags)
    {
        auto ctx = root.dup;
        ctx["tag"] = sv.tags[i];
        Value posts;
        sv.tags[i].d.get("posts", posts);
        ctx["posts"] = posts;
        files ~= OutputFile("tags/" ~ t.slug ~ "/index.html", engine.render("tag.html", ctx));
    }

    files ~= OutputFile("feed.xml", renderFeed(site));
    files ~= OutputFile("sitemap.xml", renderSitemap(site));
    return files;
}

/// Generates the site described by `src`, in memory (apart from the static
/// files, which are not read).
OutputFile[] generate(const SiteSource src)
{
    auto site = buildSite(src);
    auto engine = makeEngine(src);
    return generateFiles(site, engine);
}

/// Writes `files` below `outputDir`, creating directories as needed.
void writeFiles(const OutputFile[] files, string outputDir)
{
    foreach (ref f; files)
    {
        const path = buildPath(outputDir, f.path);
        mkdirRecurse(dirName(path));
        write(path, f.content);
    }
}

/// Copies every file under `staticDir` to `outputDir`, byte for byte,
/// keeping its relative path.
void copyStatic(string staticDir, string outputDir)
{
    foreach (DirEntry e; dirEntries(staticDir, SpanMode.breadth))
    {
        if (!e.isFile) continue;
        const dest = buildPath(outputDir, relativePath(e.name, staticDir));
        mkdirRecurse(dirName(dest));
        copy(e.name, dest);
    }
}

/**
 * Generates the site in directory `inputDir` into `outputDir`.
 *
 * Throws: an exception if the source is malformed, a template fails or a
 * file cannot be read or written.
 */
void generateSite(string inputDir, string outputDir)
{
    auto src = loadSource(inputDir);
    auto files = generate(src);
    mkdirRecurse(outputDir);
    writeFiles(files, outputDir);
    if (src.staticDir !is null) copyStatic(src.staticDir, outputDir);
}

unittest
{
    // The worked example of the specification.
    SiteSource src;
    src.config = "title = \"Pond Notes\"\nbase_url = \"https://pond.example\"\nauthor = \"R. Duck\"\nposts_per_page = 1\n";
    src.posts = [
        SourceFile("hello-world.md", "+++\ntitle = \"Hello, world\"\ndate = \"2024-01-10\"\ntags = [\"Meta\"]\n+++\nThe **first** post.\n\nMore text.\n"),
        SourceFile("on-ducks.md", "+++\ntitle = \"On Ducks\"\ndate = \"2024-02-01\"\ntags = [\"Birds\", \"Meta\"]\nslug = \"ducks\"\n+++\nDucks are *fine*.\n"),
    ];
    src.pages = [SourceFile("about.md", "+++\ntitle = \"About\"\n+++\n# About\n\nNothing here.\n")];
    src.templates = [
        SourceFile("base.html", "<!doctype html>\n<title>{% block title %}{{ site.title }}{% endblock %}</title>\n{% block body %}{% endblock %}\n"),
        SourceFile("index.html", "{% extends \"base.html\" %}\n{% block body %}{% for post in posts %}<h2><a href=\"{{ post.url }}\">{{ post.title }}</a></h2>\n{{ post.excerpt }}{% endfor %}<p>page {{ pagination.number }} of {{ pagination.total_pages }}</p>\n{% if pagination.has_next %}<a href=\"{{ pagination.next_url }}\">older</a>{% endif %}{% endblock %}\n"),
        SourceFile("post.html", "{% extends \"base.html\" %}\n{% block title %}{{ post.title }} · {{ site.title }}{% endblock %}\n{% block body %}<article>\n{{ post.content }}</article>\n<p>{{ post.date_long }}{% for t in post.tags %} <a href=\"{{ t.url }}\">{{ t.name }}</a>{% endfor %}</p>\n{% if post.older %}<a href=\"{{ post.older.url }}\">{{ post.older.title }}</a>{% endif %}{% endblock %}\n"),
        SourceFile("page.html", "{% extends \"base.html\" %}\n{% block title %}{{ page.title }}{% endblock %}\n{% block body %}{{ page.content }}{% endblock %}\n"),
        SourceFile("tag.html", "{% extends \"base.html\" %}\n{% block body %}<h1>{{ tag.name }} ({{ tag.post_count }})</h1>\n<ul>{% for post in posts %}<li>{{ post.title }}</li>{% endfor %}</ul>{% endblock %}\n"),
        SourceFile("tags.html", "{% extends \"base.html\" %}\n{% block body %}<ul>{% for t in tags %}<li><a href=\"{{ t.url }}\">{{ t.name }}</a> {{ t.post_count }}</li>{% endfor %}</ul>{% endblock %}\n"),
    ];
    string[string] out_;
    foreach (f; generate(src)) out_[f.path] = f.content;

    assert(out_.length == 10);
    assert(out_["index.html"] == "<!doctype html>\n<title>Pond Notes</title>\n<h2><a href=\"/posts/ducks/\">On Ducks</a></h2>\n"
            ~ "<p>Ducks are <em>fine</em>.</p>\n<p>page 1 of 2</p>\n<a href=\"/page/2/\">older</a>");
    assert(out_["posts/ducks/index.html"] == "<!doctype html>\n<title>On Ducks · Pond Notes</title>\n<article>\n"
            ~ "<p>Ducks are <em>fine</em>.</p>\n</article>\n<p>February 1, 2024 <a href=\"/tags/birds/\">Birds</a> <a href=\"/tags/meta/\">Meta</a></p>\n"
            ~ "<a href=\"/posts/hello-world/\">Hello, world</a>");
    assert(out_["tags/index.html"] == "<!doctype html>\n<title>Pond Notes</title>\n"
            ~ "<ul><li><a href=\"/tags/birds/\">Birds</a> 1</li><li><a href=\"/tags/meta/\">Meta</a> 2</li></ul>");
    assert(out_["feed.xml"] == "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\">\n"
            ~ "  <title>Pond Notes</title>\n  <id>https://pond.example/</id>\n  <updated>2024-02-01T00:00:00Z</updated>\n"
            ~ "  <link href=\"https://pond.example/\" rel=\"alternate\"/>\n  <link href=\"https://pond.example/feed.xml\" rel=\"self\"/>\n"
            ~ "  <author>\n    <name>R. Duck</name>\n  </author>\n  <entry>\n    <title>On Ducks</title>\n"
            ~ "    <id>https://pond.example/posts/ducks/</id>\n    <updated>2024-02-01T00:00:00Z</updated>\n"
            ~ "    <link href=\"https://pond.example/posts/ducks/\" rel=\"alternate\"/>\n"
            ~ "    <content type=\"html\">&lt;p&gt;Ducks are &lt;em&gt;fine&lt;/em&gt;.&lt;/p&gt;\n</content>\n  </entry>\n</feed>\n");
    assert(("page/2/index.html" in out_) !is null && ("about/index.html" in out_) !is null);
    string sitemap = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n";
    foreach (loc; ["/", "/page/2/", "/posts/ducks/", "/posts/hello-world/", "/about/", "/tags/", "/tags/birds/", "/tags/meta/"])
    {
        sitemap ~= "  <url>\n    <loc>https://pond.example" ~ loc ~ "</loc>\n";
        if (loc == "/posts/ducks/") sitemap ~= "    <lastmod>2024-02-01</lastmod>\n";
        if (loc == "/posts/hello-world/") sitemap ~= "    <lastmod>2024-01-10</lastmod>\n";
        sitemap ~= "  </url>\n";
    }
    assert(out_["sitemap.xml"] == sitemap ~ "</urlset>\n");
}

unittest
{
    // End to end on the file system, including nested and binary static files.
    import std.file : exists, mkdirRecurse, readText, read, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir, "sitegen-test-" ~ randomUUID().toString);
    const input = buildPath(root, "in");
    const output = buildPath(root, "out");
    scope (exit) rmdirRecurse(root);
    mkdirRecurse(buildPath(input, "content", "posts"));
    mkdirRecurse(buildPath(input, "templates"));
    mkdirRecurse(buildPath(input, "static", "css", ".hidden"));
    write(buildPath(input, "site.toml"),
        "title = \"S\"\nbase_url = \"https://s.example\"\nauthor = \"A\"\nposts_per_page = 10\n");
    write(buildPath(input, "content", "posts", "one.md"),
        "+++\ntitle = \"One\"\ndate = \"2020-01-02\"\ntags = [\"C++\"]\n+++\nHello\n");
    write(buildPath(input, "content", "posts", "ignored.txt"), "not a post");
    foreach (t; ["index.html", "post.html", "page.html", "tag.html", "tags.html"])
        write(buildPath(input, "templates", t), t ~ "\n");
    write(buildPath(input, "templates", "post.html"), "{{ post.title }}|{{ post.content }}\n");
    const binary = cast(immutable(ubyte)[]) [0, 255, 10, 13, 0, 1];
    write(buildPath(input, "static", "css", ".hidden", "bin.dat"), binary);
    write(buildPath(input, "static", "robots.txt"), "");

    generateSite(input, output);

    assert(readText(buildPath(output, "index.html")) == "index.html");
    assert(readText(buildPath(output, "posts", "one", "index.html")) == "One|<p>Hello</p>\n");
    assert(exists(buildPath(output, "tags", "c", "index.html")));
    assert(read(buildPath(output, "css", ".hidden", "bin.dat")) == binary);
    assert(read(buildPath(output, "robots.txt")).length == 0);
    assert(!exists(buildPath(output, "ignored.txt")));
}
