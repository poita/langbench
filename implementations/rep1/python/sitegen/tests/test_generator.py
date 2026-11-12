import os

import pytest

import sitegen
from sitegen import ContentError, build_model, generate, read_source, render_pages
from sitegen.feeds import render_feed, render_sitemap, xml_attr, xml_text
from sitegen.model import build_pagination

from conftest import FILES, SITE_TOML, TEMPLATES, read_tree, write_tree

INDEX_1 = (
    "<!doctype html>\n<title>Pond Notes</title>\n"
    '<h2><a href="/posts/ducks/">On Ducks</a></h2>\n<p>Ducks are <em>fine</em>.</p>\n'
    '<p>page 1 of 2</p>\n<a href="/page/2/">older</a>'
)

POST_DUCKS = (
    "<!doctype html>\n<title>On Ducks · Pond Notes</title>\n<article>\n<p>Ducks are <em>fine</em>.</p>\n"
    '</article>\n<p>February 1, 2024 <a href="/tags/birds/">Birds</a> <a href="/tags/meta/">Meta</a></p>\n'
    '<a href="/posts/hello-world/">Hello, world</a>'
)

FEED = """<?xml version="1.0" encoding="utf-8"?>
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
"""

SITEMAP = """<?xml version="1.0" encoding="utf-8"?>
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
"""


def test_worked_example(pond, tmp_path):
    out = tmp_path / "out"
    generate(pond, str(out))
    tree = read_tree(str(out))
    assert sorted(tree) == sorted([
        "index.html", "page/2/index.html", "posts/ducks/index.html", "posts/hello-world/index.html",
        "about/index.html", "tags/index.html", "tags/birds/index.html", "tags/meta/index.html",
        "feed.xml", "sitemap.xml", "robots.txt",
    ])
    text = {name: data.decode("utf-8") for name, data in tree.items()}
    assert text["index.html"] == INDEX_1
    assert text["posts/ducks/index.html"] == POST_DUCKS
    assert text["tags/index.html"] == (
        '<!doctype html>\n<title>Pond Notes</title>\n<ul><li><a href="/tags/birds/">Birds</a> 1</li>'
        '<li><a href="/tags/meta/">Meta</a> 2</li></ul>'
    )
    assert text["feed.xml"] == FEED
    assert text["sitemap.xml"] == SITEMAP
    assert text["robots.txt"] == "User-agent: *\n"
    assert text["page/2/index.html"].startswith("<!doctype html>\n<title>Pond Notes</title>\n<h2>")
    assert "<p>page 2 of 2</p>" in text["page/2/index.html"]
    assert text["tags/meta/index.html"].endswith("<ul><li>On Ducks</li><li>Hello, world</li></ul>")


def test_render_pages_does_not_touch_disk(pond):
    files = render_pages(read_source(pond))
    assert files["index.html"] == INDEX_1
    assert "robots.txt" not in files


def test_model_ordering_and_links(pond):
    model = build_model(read_source(pond))
    assert [p["slug"] for p in model.posts] == ["ducks", "hello-world"]
    ducks, hello = model.posts
    assert ducks["newer"] is None and ducks["older"]["slug"] == "hello-world"
    assert hello["older"] is None and hello["newer"]["permalink"] == "https://pond.example/posts/ducks/"
    assert [t["slug"] for t in model.tags] == ["birds", "meta"]
    assert [t["name"] for t in ducks["tags"]] == ["Birds", "Meta"]
    # objects are built once and shared
    assert ducks["tags"][1] is model.tag_links[1]
    assert model.tags[1]["posts"][0] is ducks
    assert hello["newer"] is ducks["older"] or hello["newer"]["slug"] == "ducks"
    assert [p["slug"] for p in model.pages] == ["about"]
    assert model.page_links == [{"title": "About", "slug": "about", "url": "/about/"}]
    assert ducks["excerpt"] == "<p>Ducks are <em>fine</em>.</p>\n"
    assert hello["excerpt"] == "<p>The <strong>first</strong> post.</p>\n"
    assert model.total_pages == 2


def test_pagination_values(pond):
    model = build_model(read_source(pond))
    first = build_pagination(model, 1)
    assert list(first) == ["number", "total_pages", "total_posts", "has_prev", "has_next", "prev_url", "next_url", "links"]
    assert (first["has_prev"], first["has_next"], first["prev_url"], first["next_url"]) == (False, True, None, "/page/2/")
    assert first["links"] == [
        {"number": 1, "url": "/", "current": True},
        {"number": 2, "url": "/page/2/", "current": False},
    ]
    second = build_pagination(model, 2)
    assert (second["prev_url"], second["next_url"]) == ("/", None)
    assert second["total_posts"] == 2


def make_site(tmp_path, posts=(), pages=(), config=SITE_TOML, templates=TEMPLATES, extra=None):
    root = str(tmp_path / "src")
    files = {"site.toml": config, **templates}
    for name, text in posts:
        files[f"content/posts/{name}.md"] = text
    for name, text in pages:
        files[f"content/pages/{name}.md"] = text
    files.update(extra or {})
    write_tree(root, files)
    return root


def post(title, date, tags=(), slug=None, draft=False, body="Body\n"):
    lines = [f'title = "{title}"', f'date = "{date}"']
    if tags:
        lines.append("tags = [" + ", ".join(f'"{t}"' for t in tags) + "]")
    if slug:
        lines.append(f'slug = "{slug}"')
    if draft:
        lines.append("draft = true")
    return "+++\n" + "\n".join(lines) + "\n+++\n" + body


def test_site_without_posts(tmp_path):
    root = make_site(tmp_path)
    files = render_pages(read_source(root))
    assert sorted(files) == ["feed.xml", "index.html", "sitemap.xml", "tags/index.html"]
    assert "<p>page 1 of 1</p>" in files["index.html"]
    assert files["feed.xml"].endswith("  </author>\n</feed>\n")
    assert "<updated>1970-01-01T00:00:00Z</updated>" in files["feed.xml"]
    assert files["sitemap.xml"].count("<url>") == 2


def test_canonical_order_ties_and_drafts_and_pagination(tmp_path):
    posts = [
        ("b", post("B", "2024-05-01", ["x"])),
        ("a", post("A", "2024-05-01", ["x", "y"])),
        ("c", post("C", "2024-06-01")),
        ("old", post("Old", "2020-01-01", ["z"])),
        ("draft", post("Draft", "2025-01-01", ["onlydraft"], draft=True)),
        ("s", post("S", "2024-05-01", slug="aa")),
    ]
    root = make_site(tmp_path, posts, config=SITE_TOML.replace("= 1", "= 2"))
    model = build_model(read_source(root))
    assert [p["slug"] for p in model.posts] == ["c", "a", "aa", "b", "old"]
    assert model.total_pages == 3
    assert [p["slug"] for p in model.index_posts(2)] == ["aa", "b"]
    assert [p["slug"] for p in model.index_posts(3)] == ["old"]
    assert [t["name"] for t in model.tags] == ["x", "y", "z"]
    assert [t["post_count"] for t in model.tags] == [2, 1, 1]
    files = render_pages(read_source(root))
    assert "posts/draft/index.html" not in files
    assert "tags/onlydraft/index.html" not in files
    # neighbours are site-wide, not per list
    xs = model.tags[0]["posts"]
    assert [p["slug"] for p in xs] == ["a", "b"]
    assert xs[0]["older"]["slug"] == "aa" and xs[1]["newer"]["slug"] == "aa"
    # the feed holds the first posts_per_page posts
    assert files["feed.xml"].count("<entry>") == 2
    assert "<updated>2024-06-01T00:00:00Z</updated>" in files["feed.xml"]


def test_duplicate_tags_in_a_post_are_dropped(tmp_path):
    root = make_site(tmp_path, [("p", post("P", "2024-01-01", ["A b", "C", "A b"]))])
    model = build_model(read_source(root))
    assert [t["name"] for t in model.posts[0]["tags"]] == ["A b", "C"]
    assert model.tag_links[0] == {"name": "A b", "slug": "a-b", "url": "/tags/a-b/", "post_count": 1}


def test_feed_and_sitemap_escaping(tmp_path):
    config = SITE_TOML.replace("Pond Notes", 'A & B <\\"x\\">').replace("R. Duck", "O'Neil & <Co>")
    root = make_site(tmp_path, [("p", post('T <&> \\"q\\"', "2024-01-01", body="a < b & \"c\"\n"))], config=config)
    files = render_pages(read_source(root))
    feed = files["feed.xml"]
    assert "<title>A &amp; B &lt;\"x\"&gt;</title>" in feed
    assert "<name>O'Neil &amp; &lt;Co&gt;</name>" in feed
    assert "<title>T &lt;&amp;&gt; \"q\"</title>" in feed
    assert "&lt;p&gt;a &amp;lt; b &amp;amp; &amp;quot;c&amp;quot;&lt;/p&gt;\n</content>" in feed


def test_xml_escape_helpers():
    assert xml_text("a&b<c>d\"e'f") == "a&amp;b&lt;c&gt;d\"e'f"
    assert xml_attr("a&b<c>d\"e'f") == "a&amp;b&lt;c&gt;d&quot;e'f"


def test_templates_see_site_variables_and_unicode(tmp_path):
    templates = dict(TEMPLATES)
    templates["templates/index.html"] = "{{ site.tagline }}|{{ site.year }}|{{ site.keywords|join(',') }}|{{ site.on }}|{{ pages|length }}|{{ tags|length }}"
    config = SITE_TOML + 'tagline = "caf\\u00e9 \\"x\\""\nyear = -4\nkeywords = ["a", "b"]\non = true\n'
    root = make_site(tmp_path, config=config, templates=templates)
    assert render_pages(read_source(root))["index.html"] == 'café "x"|-4|a,b|True|0|0'


def test_template_source_loses_exactly_one_trailing_newline(tmp_path):
    templates = dict(TEMPLATES)
    templates["templates/tags.html"] = "tags\n\n"
    templates["templates/tag.html"] = "x"
    root = make_site(tmp_path, templates=templates)
    assert render_pages(read_source(root))["tags/index.html"] == "tags\n"


def test_static_files_are_copied_verbatim(tmp_path):
    blob = bytes(range(256)) + b"\r\n\x00end"
    extra = {
        "static/css/site.css": "body { }\r\n",
        "static/.hidden/.file": b"hidden",
        "static/a/b/c/deep.bin": blob,
        "static/empty.txt": b"",
    }
    root = make_site(tmp_path, extra=extra)
    os.makedirs(os.path.join(root, "static", "emptydir"))
    out = tmp_path / "out"
    generate(root, str(out))
    tree = read_tree(str(out))
    assert tree["css/site.css"] == b"body { }\r\n"
    assert tree[".hidden/.file"] == b"hidden"
    assert tree["a/b/c/deep.bin"] == blob
    assert tree["empty.txt"] == b""
    assert not (out / "emptydir").exists()


def test_output_directory_is_created_when_missing(pond, tmp_path):
    target = tmp_path / "does" / "not" / "exist"
    generate(pond, str(target))
    assert (target / "index.html").is_file()


def test_non_markdown_entries_are_ignored(tmp_path):
    root = make_site(tmp_path, [("p", post("P", "2024-01-01"))], extra={
        "content/posts/notes.txt": "ignored", "content/pages/readme": "ignored", "templates/extra.txt": "x",
    })
    os.makedirs(os.path.join(root, "content", "posts", "dir.md"))
    assert sorted(f for f in render_pages(read_source(root)) if f.startswith("posts/")) == ["posts/p/index.html"]


def test_invalid_configuration_raises(tmp_path):
    with pytest.raises(ContentError):
        read_source(make_site(tmp_path, config='title = "x"\n'))


def test_public_api_is_exported():
    for name in sitegen.__all__:
        assert hasattr(sitegen, name)


def test_feed_uses_base_url_with_a_path(tmp_path):
    config = SITE_TOML.replace("https://pond.example", "https://example.com/blog")
    root = make_site(tmp_path, [("p", post("P", "2024-01-01"))], config=config)
    model = build_model(read_source(root))
    assert model.posts[0]["permalink"] == "https://example.com/blog/posts/p/"
    assert "<id>https://example.com/blog/</id>" in render_feed(model)
    assert "<loc>https://example.com/blog/page/2/</loc>" not in render_sitemap(model)
