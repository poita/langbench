# sitegen

A small static site generator written in Rust with **no dependencies**
beyond the standard library.

`sitegen` reads a site source directory (a `site.toml`, Markdown posts and
pages with TOML front matter, Jinja-style templates and static files) and
writes a complete static website: post pages, pages, tag pages, paginated
index pages, an Atom feed and a sitemap.

The three small languages involved are implemented from scratch and are
usable on their own as library modules:

| Module | What it is |
|--------|-----------|
| `sitegen::markdown` | CommonMark-subset to HTML converter (matches `cmark` 0.31.2) |
| `sitegen::template` | Jinja2-subset template engine (`extends`/`block`/`super()`, macros, `include`, filters, whitespace control) |
| `sitegen::toml` | Reader for the TOML subset used by configuration and front matter |

On top of them sit `content` (reading a source directory), `site` (the
content model: ordering, tags, pagination), `context` (the values templates
see), `feed` (Atom feed and sitemap) and `generate` (the pipeline).

## Building

```sh
cargo build --release        # or ./build.sh
```

The binary is `target/release/sitegen`. `./run.sh <input> <output>` runs it
from any directory.

## Command line

```text
sitegen <input directory> <output directory>
```

The input directory is the site source. The output directory is created if it
does not exist; the program writes only inside it. The exit status is `0` on
success, `1` if the site could not be built (the reason is printed on stderr)
and `2` for a usage error.

### Input layout

```text
<input>/
    site.toml                 required: title, base_url, author, posts_per_page
    content/
        posts/*.md            optional
        pages/*.md            optional
    templates/*.html          required: index, post, page, tag, tags
    static/**                 optional, copied verbatim
```

A content file is Markdown preceded by TOML front matter:

```text
+++
title = "Hello, world"
date = "2024-01-10"
tags = ["Meta", "News"]
+++
The **first** post.
```

Posts take `title`, `date` (`YYYY-MM-DD`), and optionally `slug`, `tags` and
`draft`; pages take `title` and optionally `slug` and `draft`. Drafts are
excluded from everything. `site.toml` may hold further keys of its own; they
are available to templates as `site.<key>`.

### Output layout

| File | Template |
|------|----------|
| `index.html`, `page/N/index.html` | `index.html` (`posts`, `pagination`) |
| `posts/<slug>/index.html` | `post.html` (`post`) |
| `<page slug>/index.html` | `page.html` (`page`) |
| `tags/index.html` | `tags.html` |
| `tags/<tag slug>/index.html` | `tag.html` (`tag`, `posts`) |
| `feed.xml`, `sitemap.xml` | generated |
| everything under `static/` | copied byte for byte |

Every template also sees `site`, `tags` (tag links) and `pages` (page
links). Posts are ordered newest first (ties by slug); tags and pages by
slug. A post carries `title`, `slug`, `url`, `permalink`, `date`,
`date_long`, `tags`, `content`, `excerpt` and its site-wide `older` / `newer`
neighbours. `pagination` has `number`, `total_pages`, `total_posts`,
`has_prev`, `has_next`, `prev_url`, `next_url` and `links`.

A template's source is the file with one trailing newline removed, as in
Jinja2, and the rendering is written verbatim.

## Library

```rust
use sitegen::markdown;
use sitegen::template::{Dict, Environment, Value};

// Markdown to HTML.
assert_eq!(
    markdown::to_html("Some *emphasis*.\n"),
    "<p>Some <em>emphasis</em>.</p>\n"
);

// Templates.
let mut env = Environment::new();
env.add_template("base", "<h1>{% block title %}{% endblock %}</h1>");
env.add_template(
    "page",
    "{% extends 'base' %}{% block title %}{{ name|upper }} ({{ n }}){% endblock %}",
);
let mut ctx = Dict::new();
ctx.insert("name", Value::str("sitegen"));
ctx.insert("n", Value::Int(3));
assert_eq!(env.render("page", &ctx).unwrap(), "<h1>SITEGEN (3)</h1>");

// A whole site: read, build in memory, write.
// sitegen::generate(Path::new("my-site"), Path::new("public"))?;
//
// or step by step:
// let source = sitegen::content::load(Path::new("my-site"))?;
// let files = sitegen::generate::build(&source)?;
// sitegen::generate::write(&files, Path::new("public"))?;
```

`cargo doc --open` shows the full API.

## Template language

`{{ expr }}`, `{% if/elif/else %}`, `{% for %}…{% else %}` (with
`loop.index`, `loop.index0`, `loop.first`, `loop.last`, `loop.length`),
`{% set %}`, `{% macro %}`, `{% include %}`, `{% extends %}` /
`{% block %}` / `super()`, `{# comments #}` and `-` whitespace control. The
filters are `upper`, `lower`, `trim`, `escape`, `replace`, `length`, `int`,
`join`, `first`, `last`, `reverse`, `sort` and `default`; the builtin
function is `range`. Autoescaping is off, and, like Jinja2 with
`StrictUndefined`, using an undefined value (other than with `is defined` or
`default`) is an error.

## Tests

```sh
cargo test --release
```

* unit tests next to the code (TOML, templates, filters, content model);
* `tests/markdown.rs`: a table of inputs whose expected HTML was produced by
  `cmark` 0.31.2, plus robustness checks (deep nesting);
* `tests/site.rs`: whole sites built in temporary directories, including the
  worked example of the specification, and the command-line tool;
* doc tests for the public examples.

## Layout of the source

```text
src/
  main.rs         command-line tool
  lib.rs          crate documentation and re-exports
  error.rs        site generator errors
  toml.rs         TOML subset
  content.rs      reading a source directory
  site.rs         content model
  context.rs      template values
  feed.rs         feed.xml and sitemap.xml
  generate.rs     build / write / generate
  markdown/       block.rs (block structure), inline.rs (emphasis, links, …), html.rs
  template/       lexer.rs, parser.rs, ast.rs, eval.rs, ops.rs, filters.rs, value.rs
examples/markdown.rs   stdin → stdout Markdown converter
```
