# sitegen

A small static site generator written in D with nothing but the standard
library. It reads a site directory (a TOML-subset configuration, Markdown
content with front matter, Jinja-style templates and static files) and writes a
complete website: index pages with pagination, posts, pages, tag pages, an Atom
feed and a sitemap.

The three languages involved are implemented from scratch, as modules of a
reusable library:

| Module | What it does |
|--------|--------------|
| `sitegen.markdown` | CommonMark-subset to HTML converter. It reproduces `cmark` 0.31.2 for the supported constructs: ATX/setext headings, paragraphs, block quotes, lists (tight/loose), code blocks, thematic breaks, emphasis, code spans, links, images, autolinks, escapes, entities and line breaks. Raw HTML and link reference definitions are not supported. |
| `sitegen.templating` | Jinja2-subset template engine: `{{ }}`, `if`/`for`/`set`/`macro`/`include`/`extends`/`block` with `super()`, comments, whitespace control, 13 filters, shared-reference values and a parse cache. |
| `sitegen.toml` | The TOML subset used by `site.toml` and front matter (strings, integers, booleans, string arrays). |
| `sitegen.frontmatter`, `sitegen.model` | Splitting `+++` front matter, post/page/tag model, ordering, slugs, dates, excerpts. |
| `sitegen.render`, `sitegen.feed`, `sitegen.xml` | Template values, page rendering, `feed.xml` and `sitemap.xml`. |
| `sitegen.generator` | Reading a directory tree and writing the output tree (including `static/`). |

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh            # dub build -b release --compiler=ldc2  ->  bin/sitegen
dub test --compiler=ldc2   # unit tests
```

`dub build -c library` builds only the library (`bin/libsitegen.a`).

## Command line

```sh
./run.sh <input directory> <output directory>
# or
bin/sitegen <input directory> <output directory>
```

The input directory has this layout:

```
site.toml                  title, base_url, author, posts_per_page (+ any extra keys)
content/posts/*.md         posts: front matter title, date (YYYY-MM-DD), slug, tags, draft
content/pages/*.md         pages: front matter title, slug, draft
templates/*.html           index.html, post.html, page.html, tag.html, tags.html (+ includes/bases)
static/**                  copied verbatim
```

The output directory receives `index.html`, `page/N/index.html`, `posts/<slug>/index.html`,
`<page-slug>/index.html`, `tags/index.html`, `tags/<tag-slug>/index.html`, `feed.xml`,
`sitemap.xml` and the static files. The exit code is 0 on success; on any error a
message goes to stderr and the exit code is non-zero (1 for a bad site, 2 for bad usage).

Content file example:

```
+++
title = "Hello, world"
date = "2024-01-10"
tags = ["Meta", "Web Development"]
+++
The **first** post.
```

Template example (`templates/index.html`):

```
{% for post in posts %}<h2><a href="{{ post.url }}">{{ post.title }}</a></h2>
{{ post.excerpt }}{% endfor %}
{% if pagination.has_next %}<a href="{{ pagination.next_url }}">older</a>{% endif %}
```

## Using the library

Convert Markdown:

```d
import sitegen.markdown;

void main()
{
    assert(markdownToHtml("# Hi\n\nSome *text*.\n") == "<h1>Hi</h1>\n<p>Some <em>text</em>.</p>\n");
}
```

Render a template:

```d
import sitegen.templating;

void main()
{
    auto engine = new Engine((string name, out string source) {
        if (name != "page")
            return false;
        source = "{% for x in xs %}[{{ x|upper }}]{% endfor %}";
        return true;
    });
    auto root = new Scope;
    root.set("xs", Value.of([Value.of("a"), Value.of("b")]));
    assert(engine.render("page", root) == "[A][B]");   // throws TemplateError on failure
}
```

Generate a whole site in memory:

```d
import sitegen;

void main()
{
    SiteSource src;
    src.siteToml = "title = \"T\"\nbase_url = \"https://example.com\"\nauthor = \"A\"\nposts_per_page = 5\n";
    src.posts["hello.md"] = "+++\ntitle = \"Hello\"\ndate = \"2024-01-01\"\n+++\nHi!\n";
    foreach (name; ["index", "post", "page", "tag", "tags"])
        src.templates[name ~ ".html"] = "{{ site.title }}";

    foreach (file; renderSite(src))   // OutputFile(path, content)
        { /* write file.content to file.path */ }
}
```

or write a directory to disk with `generateSite(inputDir, outputDir)`.

## Layout of the repository

```
source/sitegen/   the library (one directory per sub-language)
app/main.d        the command-line tool (a thin wrapper over generateSite)
tests/            unit tests, one file per area (run by `dub test`)
build.sh run.sh   build and run helpers
```

## Design notes

* Single-threaded pipeline: load, build the model (each body converted once,
  excerpts from the first block), build every template value once as a shared
  immutable value, render each page, write each file with a single write.
* Markdown follows the reference algorithm: line-driven block parser (open-block
  chain, container starts, lazy continuation), delimiter stack with the
  rule-of-3 and `openers_bottom` bounds, a bracket stack, and the code-span
  backtick memo, so pathological inputs stay linear.
* The template engine parses each template once (cached), resolves operators
  and filters at parse time, shares strings/lists/dicts by reference and uses
  small linearly searched scopes. Errors are exceptions (`TemplateError` with
  an `ErrorKind`); unknown filters are reported only after the whole template has
  parsed so syntax errors win.
