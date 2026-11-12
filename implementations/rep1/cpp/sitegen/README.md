# sitegen

A small static site generator written in C++20 with no dependencies beyond the
standard library. It reads a site directory (configuration, Markdown content,
templates, static files) and writes a complete static website: index pages with
pagination, post, page and tag pages, an Atom feed and a sitemap.

The three pieces that usually come from third-party libraries are implemented
here from scratch and are usable on their own:

| Module | Header | What it is |
|--------|--------|------------|
| Markdown | `sitegen/markdown.hpp` | a CommonMark subset converter (blocks, lists, emphasis, links, images, code, autolinks) that matches `cmark` 0.31.2 on that subset |
| Templates | `sitegen/template.hpp`, `sitegen/value.hpp` | a Jinja-style engine: expressions, 13 filters, `if`/`for`/`set`/`macro`/`include`/`extends`/`block`/`super()` |
| TOML subset | `sitegen/toml.hpp` | `key = value` lines (string, integer, boolean, string array) for `site.toml` and front matter |

On top of those, `sitegen/source.hpp`, `sitegen/model.hpp` and
`sitegen/generator.hpp` load a site, build the content model (ordering, tags,
pagination, template objects) and render the output.

## Building

Requirements: a C++20 compiler, CMake 3.20+, and GoogleTest for the tests.

```sh
./build.sh                 # Release build into ./build (library, CLI and tests)
./run.sh <input> <output>  # run the CLI
```

`build.sh` and `run.sh` work from any directory. Or use CMake directly:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build          # run the unit tests
cmake --install build --prefix /usr/local
```

Pass `-DSITEGEN_BUILD_TESTS=OFF` to skip the tests (and the GoogleTest
requirement).

## Command line

```
sitegen <input directory> <output directory>
```

The output directory is created if it does not exist. Nothing is read from
stdin; errors go to stderr and give a non-zero exit status (`0` on success).
`sitegen --help` prints a usage summary.

### Input layout

```
site.toml                  required: title, base_url, author, posts_per_page (+ any extras)
content/posts/*.md         posts   (directory optional)
content/pages/*.md         pages   (directory optional)
templates/*.html           index.html post.html page.html tag.html tags.html (required) + helpers
static/**                  copied verbatim (directory optional)
```

A content file starts with TOML front matter between `+++` lines:

```
+++
title = "Hello, world"
date = "2024-01-10"          # posts only
tags = ["Meta", "C++"]       # posts only, optional
slug = "hello"               # optional, default: file name without .md
draft = false                # optional
+++
Markdown body…
```

`base_url` has no trailing `/`. Drafts are excluded everywhere.

### Output

`index.html` and `page/N/index.html` (pagination), `posts/<slug>/index.html`,
`<page-slug>/index.html`, `tags/index.html`, `tags/<tag-slug>/index.html`,
`feed.xml`, `sitemap.xml`, and every file of `static/` at the same relative path.
Posts are ordered newest first (ties by slug); tag slugs are the lower-cased
name with every other run of characters turned into `-` (`C++` → `c`).

### Template variables

Every template gets `site` (the parsed `site.toml`), `tags` (tag links:
`name slug url post_count`) and `pages` (page links: `title slug url`).

| Template | Extra variables |
|----------|-----------------|
| `index.html` | `posts` (post objects for this page), `pagination` (`number total_pages total_posts has_prev has_next prev_url next_url links`) |
| `post.html` | `post` (`title slug url permalink date date_long tags content excerpt older newer`) |
| `page.html` | `page` (`title slug url permalink content`) |
| `tag.html` | `tag` (`name slug url post_count posts`), `posts` |

Templates `include` and `extends` each other by file name (`"base.html"`). The
`content` and `excerpt` strings are HTML and are not escaped on output; nothing
is escaped automatically (use `|escape` where needed).

### Template language

* `{{ expr }}`, `{% statement %}`, `{# comment #}`; a `-` next to a delimiter
  (`{{-`, `-%}`, …) trims adjacent whitespace. No automatic trimming.
* Statements: `if/elif/else/endif`, `for/else/endfor` (`loop.index`,
  `loop.index0`, `loop.first`, `loop.last`, `loop.length`), `set`,
  `macro/endmacro`, `include`, `extends`, `block/endblock` with `super()`.
* Expressions: literals, lists, `.attr` / `[index]`, calls (macros, `range`),
  `+ - * / // % **`, `~` (concatenation), comparisons (chained), `in`/`not in`,
  `and`/`or`/`not` (returning operands), `is defined`/`is not defined`.
* Filters: `upper lower trim escape replace length int join first last reverse
  sort default`.
* Undefined values are strict: using one (other than `is defined` and
  `|default`) is an error, as are wrong operand types. Rendering is
  all-or-nothing.

## Using the library

```cpp
#include <iostream>

#include "sitegen/sitegen.hpp"

int main() {
  // Markdown on its own.
  std::cout << sitegen::markdown_to_html("Hello *world*\n");  // <p>Hello <em>world</em></p>

  // Templates on their own.
  sitegen::TemplateEngine engine;
  engine.add_template("base.html", "<h1>{% block title %}{% endblock %}</h1>");
  engine.add_template("page.html",
                      "{% extends \"base.html\" %}{% block title %}{{ name|upper }}{% endblock %}");
  sitegen::Dict context;
  context.set("name", sitegen::Value::string("hello"));
  std::cout << engine.render("page.html", context) << "\n";  // <h1>HELLO</h1>

  // A whole site, built from memory instead of from a directory.
  sitegen::SiteSource source;
  source.config = sitegen::toml::parse(
      "title = \"Demo\"\nbase_url = \"https://example.com\"\nauthor = \"Me\"\nposts_per_page = 5\n");
  source.posts.push_back(sitegen::parse_post(
      "hi", "+++\ntitle = \"Hi\"\ndate = \"2024-01-02\"\n+++\nFirst post\n"));
  for (const char* name : {"index", "post", "page", "tag", "tags"}) {
    source.templates.emplace_back(std::string(name) + ".html", "{{ site.title }}");
  }
  const sitegen::SiteModel model = sitegen::SiteModel::build(source);
  const sitegen::TemplateEngine templates = sitegen::make_template_engine(source);
  for (const sitegen::OutputFile& file : sitegen::render_site(model, templates)) {
    std::cout << file.path << " (" << file.contents.size() << " bytes)\n";
  }
}
```

Link against the `sitegen::sitegen` CMake target (or `libsitegen.a` with the
`include/` directory on the include path). Errors are exceptions:
`sitegen::TemplateError` (with `kind()`), `sitegen::SiteError`,
`sitegen::toml::ParseError` and `std::filesystem::filesystem_error`.
Reading a directory and writing the result is `sitegen::generate_site(in, out)`.

## Project layout

```
include/sitegen/   public headers (documented)
src/               library implementation
  markdown/        block parser, inline parser, HTML renderer
  tmpl/            template lexer/parser, interpreter, engine
cli/main.cpp       the command-line tool (a thin wrapper over generate_site)
tests/             GoogleTest unit tests, one file per module
```

How it works: **load** (read `site.toml`, content, templates) → **model**
(sort, collect tags, convert each body and excerpt to HTML once, build the
shared template values) → **render** (one root scope per output page) →
**emit** (write pages, `feed.xml`, `sitemap.xml`, copy `static/`). Tag collection
is O(K + T log T); the Markdown converter is linear (backtick memo,
`openers_bottom` bounds, O(1) node moves); each template is parsed at most once
and values are shared, never copied.
