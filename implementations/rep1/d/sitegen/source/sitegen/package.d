/**
 * sitegen: a static site generator.
 *
 * The library is split by responsibility:
 *
 * $(UL
 *   $(LI `sitegen.toml`, `sitegen.frontmatter`: the TOML-subset reader and
 *        front-matter splitting)
 *   $(LI `sitegen.markdown`: the CommonMark-subset converter)
 *   $(LI `sitegen.templating`: the Jinja-style template engine)
 *   $(LI `sitegen.source`, `sitegen.model`: reading a site and building its
 *        content model)
 *   $(LI `sitegen.context`, `sitegen.feed`, `sitegen.generator`: template
 *        values, the feed and sitemap, and the generator itself))
 *
 * See the unit test below for a complete example.
 */
module sitegen;

public import sitegen.frontmatter;
public import sitegen.generator;
public import sitegen.markdown;
public import sitegen.model;
public import sitegen.source;
public import sitegen.templating;
public import sitegen.toml;

///
unittest
{
    SiteSource src;
    src.config = "title = \"T\"\nbase_url = \"https://x.example\"\n"
        ~ "author = \"A\"\nposts_per_page = 5\n";
    src.posts = [SourceFile("hi.md", "+++\ntitle = \"Hi\"\ndate = \"2024-05-06\"\n+++\nHello *you*\n")];
    src.templates = [
        SourceFile("index.html", "{% for p in posts %}{{ p.title }} ({{ p.date_long }}){% endfor %}"),
        SourceFile("post.html", "{{ post.content }}"),
        SourceFile("page.html", ""),
        SourceFile("tag.html", ""),
        SourceFile("tags.html", ""),
    ];
    string[string] files;
    foreach (f; generate(src))
        files[f.path] = f.content;
    assert(files["index.html"] == "Hi (May 6, 2024)");
    assert(files["posts/hi/index.html"] == "<p>Hello <em>you</em></p>\n");
    assert("feed.xml" in files && "sitemap.xml" in files);
}
