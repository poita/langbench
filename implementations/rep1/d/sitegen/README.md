# sitegen

A static site generator written in D. It reads a source directory — a TOML
configuration, Markdown posts and pages, templates and static files — and
writes a complete website: an index with pagination, one page per post and per
page, tag pages, an Atom feed and a sitemap.

Everything the generator needs is implemented here, using only D's standard
library:

* a **CommonMark-subset converter** (`sitegen.markdown`) whose output matches
  `cmark` 0.31.2: block structure, delimiter-stack emphasis, links, images,
  autolinks, code spans, entities and so on;
* a **Jinja-style template engine** (`sitegen.templating`) with expressions,
  filters, `if`/`for`/`set`/`macro`/`include`, and `extends`/`block`/`super()`
  inheritance;
* a reader for the **TOML subset** used by `site.toml` and front matter
  (`sitegen.toml`, `sitegen.frontmatter`).

The code is a library with a thin command-line tool on top.

## Building

Requires LDC (tested with 1.41.0) and dub (tested with 1.40.0).

```sh
dub build -b release --compiler=ldc2     # builds ./sitegen
./build.sh                               # the same, from any directory
```

`dub build --config=library` builds only the library.

## Command line

```
sitegen <input directory> <output directory>
```

The output directory is created if it does not exist. The exit status is 0 on
success; on failure a message is written to stderr and the status is non-zero.
`run.sh` is a wrapper that locates the binary relative to itself:

```sh
./run.sh my-site/ public/
```

### Input layout

```
site.toml                 title, base_url, author, posts_per_page (+ any other keys)
content/posts/*.md        posts   (TOML front matter between +++ lines, then Markdown)
content/pages/*.md        pages
templates/*.html          index.html, post.html, page.html, tag.html, tags.html (+ partials)
static/**                 copied verbatim
```

A post's front matter has `title` and `date` (`YYYY-MM-DD`) and optionally
`slug`, `tags` and `draft`; a page has `title` and optionally `slug` and
`draft`. Drafts are left out completely.

### Output layout

```
index.html, page/N/index.html        index pages (posts_per_page posts each)
posts/<slug>/index.html              one per post
<page-slug>/index.html               one per page
tags/index.html, tags/<slug>/index.html
feed.xml, sitemap.xml
```

plus every file under `static/`.

### Templates

Templates have the variables `site` (the parsed `site.toml`), `tags` and
`pages` (lists of links), and per template `posts` and `pagination`
(`index.html`), `post`, `page`, or `tag` and `posts`. A minimal `post.html`:

```jinja
{% extends "base.html" %}
{% block body %}
<h1>{{ post.title }}</h1>
<p>{{ post.date_long }}{% for t in post.tags %} <a href="{{ t.url }}">{{ t.name }}</a>{% endfor %}</p>
{{ post.content }}
{% endblock %}
```

## Using the library

Add the package to a dub project (`dependency "sitegen" path="..."` with
`subConfiguration "sitegen" "library"`), then:

```d
import sitegen;

void main()
{
    // Markdown on its own.
    assert(markdownToHtml("Hello *world*") == "<p>Hello <em>world</em></p>\n");

    // The template engine on its own.
    auto engine = new TemplateEngine;
    engine.addTemplate("hello", "Hello {{ name|upper }}!");
    Value[string] context;
    context["name"] = Value.str("world");
    assert(engine.render("hello", context) == "Hello WORLD!");

    // A whole site, in memory.
    SiteSource src;
    src.config = "title = \"Blog\"\nbase_url = \"https://example.com\"\n"
        ~ "author = \"Me\"\nposts_per_page = 5\n";
    src.posts = [SourceFile("hi.md",
        "+++\ntitle = \"Hi\"\ndate = \"2024-05-06\"\ntags = [\"News\"]\n+++\nHello *you*\n")];
    src.templates = [
        SourceFile("index.html", "{% for p in posts %}{{ p.title }}\n{% endfor %}"),
        SourceFile("post.html", "{{ post.content }}"),
        SourceFile("page.html", ""),
        SourceFile("tag.html", ""),
        SourceFile("tags.html", ""),
    ];
    foreach (file; generate(src))        // OutputFile(path, content)
        writeFiles([file], "public");    // or write them yourself
}
```

`generateSite(inputDir, outputDir)` does the whole job on the file system, as
the command-line tool does.

### Modules

| Module | Responsibility |
|--------|----------------|
| `sitegen.toml` | TOML-subset parser (`parseToml`, `TomlDocument`) |
| `sitegen.frontmatter` | splits a content file into front matter and body |
| `sitegen.markdown` | `markdownToHtml`; block parser, inline parser and HTML renderer in `sitegen.markdown.*` |
| `sitegen.templating` | `TemplateEngine`, `Value`, `Dict`, `TemplateException`; lexer, parser, interpreter and filters in `sitegen.templating.*` |
| `sitegen.source` | reads a source directory into a `SiteSource` |
| `sitegen.model` | `Site`, `Post`, `Page`, `Tag`: ordering, slugs, dates, excerpts, tag collection |
| `sitegen.context` | builds the values handed to templates |
| `sitegen.feed` | `renderFeed`, `renderSitemap` |
| `sitegen.generator` | `generate`, `generateFiles`, `generateSite`, `writeFiles`, `copyStatic` |

Each body and excerpt is converted to HTML once; post, page and tag objects
are built once and shared by every page that shows them; tags are collected in
O(K + T log T).

## Tests

```sh
dub test --compiler=ldc2
```

The tests are D `unittest` blocks next to the code they test, plus two
conformance suites: `sitegen.markdown.conformance` (expected HTML produced by
`cmark` 0.31.2) and `sitegen.templating.conformance` (expected output produced
by Jinja2 3.1 with `StrictUndefined`).
