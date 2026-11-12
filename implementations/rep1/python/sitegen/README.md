# sitegen

A small static site generator. It reads a source directory (a TOML-subset
configuration, Markdown content with front matter, Jinja-style templates and
static files) and writes a complete static website: index pages with
pagination, post, page and tag pages, an Atom feed and a sitemap.

Everything is implemented in this package using only the Python standard
library: the CommonMark-subset Markdown converter, the Jinja-subset template
engine and the TOML-subset reader are written from scratch and can be used on
their own.

Requires Python 3.14 or newer. The only dependency, for the tests, is `pytest`.

## Building

There is nothing to compile; `build.sh` byte-compiles the package:

```sh
./build.sh
```

(`pip install .` also works and installs a `sitegen` command.)

## Using the command-line tool

```sh
./run.sh <input directory> <output directory>
# or, without the script:
PYTHONPATH=src python3 -m sitegen <input directory> <output directory>
```

The output directory is created if it does not exist. The program prints
nothing on success and exits with status 0; on an invalid site it prints
`sitegen: error: ...` to stderr and exits with status 1.

### Input layout

```
<input>/
    site.toml                 required: title, base_url, author, posts_per_page
    content/
        posts/*.md            posts  (title, date, optional slug, tags, draft)
        pages/*.md            pages  (title, optional slug, draft)
    templates/*.html          index, post, page, tag and tags are required
    static/**                 copied verbatim to the output
```

A content file starts with `+++`-delimited TOML front matter, followed by the
Markdown body:

```
+++
title = "Hello, world"
date = "2024-01-10"
tags = ["Meta"]
+++
The **first** post.
```

### Output layout

| Path | Template |
|------|----------|
| `index.html`, `page/N/index.html` | `index.html` |
| `posts/<slug>/index.html` | `post.html` |
| `<page slug>/index.html` | `page.html` |
| `tags/index.html` | `tags.html` |
| `tags/<tag slug>/index.html` | `tag.html` |
| `feed.xml`, `sitemap.xml` | generated |
| every file under `static/` | copied |

Posts are ordered newest first (ties by slug). Drafts are excluded everywhere.
The variables each template receives (`site`, `tags`, `pages`, `posts`,
`post`, `page`, `tag`, `pagination`) and the exact shape of each object are
described in `problems/sitegen/SPEC.md`.

## Using the library

```python
import os
import tempfile

import sitegen
from sitegen import toml
from sitegen.markdown import to_html
from sitegen.template import Environment

# The engines work on their own.
assert toml.loads('title = "Hi"  # comment\nn = 3') == {"title": "Hi", "n": 3}
assert to_html("Some *emphasis*") == "<p>Some <em>emphasis</em></p>\n"
env = Environment({"hello": "Hello {{ name|upper }}!"})
assert env.render("hello", {"name": "world"}) == "Hello WORLD!"

# Building a whole site.
with tempfile.TemporaryDirectory() as tmp:
    src, out = os.path.join(tmp, "src"), os.path.join(tmp, "out")
    for name, text in {
        "site.toml": 'title = "T"\nbase_url = "https://x.example"\nauthor = "A"\nposts_per_page = 5\n',
        "content/posts/hi.md": '+++\ntitle = "Hi"\ndate = "2024-05-06"\ntags = ["Intro"]\n+++\nHello *there*.\n',
        "templates/index.html": "{% for p in posts %}{{ p.title }} ({{ p.date_long }}){% endfor %}",
        "templates/post.html": "{{ post.content }}",
        "templates/page.html": "{{ page.content }}",
        "templates/tag.html": "{{ tag.name }}: {{ tag.post_count }}",
        "templates/tags.html": "{% for t in tags %}{{ t.slug }} {% endfor %}",
    }.items():
        path = os.path.join(src, *name.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    # Render in memory ...
    files = sitegen.render_pages(sitegen.read_source(src))
    assert files["index.html"] == "Hi (May 6, 2024)"
    assert files["posts/hi/index.html"] == "<p>Hello <em>there</em>.</p>\n"
    assert sorted(files) == ["feed.xml", "index.html", "posts/hi/index.html",
                             "sitemap.xml", "tags/index.html", "tags/intro/index.html"]

    # ... or generate the whole site on disk, static files included.
    sitegen.generate(src, out)
    assert os.path.exists(os.path.join(out, "feed.xml"))
```

### Public API

| Name | Purpose |
|------|---------|
| `sitegen.generate(input_dir, output_dir)` | read a source directory and write the site |
| `sitegen.read_source(path)` | read and validate a source directory into a `Source` |
| `sitegen.build_model(source)` | order posts, collect tags, convert Markdown, build the template values (`SiteModel`) |
| `sitegen.render_pages(source)` | render every generated file to a `{path: text}` dict |
| `sitegen.markdown.to_html(text)` | CommonMark subset to HTML |
| `sitegen.template.Environment(sources)` | named templates; `.render(name, context)` |
| `sitegen.toml.loads(text)` | the TOML subset |

Errors derive from `sitegen.SitegenError`; template errors
(`sitegen.template.TemplateError` and subclasses) carry a `kind` of `syntax`,
`filter`, `undefined`, `template` or `type`.

### Package layout

```
src/sitegen/
    cli.py, __main__.py       command-line tool
    generator.py              rendering pages, writing files, copying static files
    model.py                  ordering, tags, pagination, template values
    source.py, content.py,
    frontmatter.py            reading the input directory and content files
    feeds.py                  feed.xml and sitemap.xml
    toml.py                   TOML-subset reader
    markdown/                 text.py, blocks.py (phase 1), inlines.py (phase 2), render.py
    template/                 lexer.py, parser.py, nodes.py, interpreter.py, filters.py, values.py
tests/                        pytest suite
```

## Tests

```sh
python3 -m pytest
```
