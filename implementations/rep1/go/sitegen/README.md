# sitegen

A small static site generator written in Go with no dependencies beyond the
standard library. It reads a site source (configuration, Markdown content,
templates, static files) and writes a complete static website: post, page and
tag pages, paginated index pages, an Atom feed and a sitemap.

The three languages it needs are implemented from scratch, as separate
packages that can be used on their own:

| Package | What it is |
|---------|------------|
| [`markdown`](markdown) | CommonMark subset to HTML. Follows the structure of `cmark`: a line-driven block parser, a delimiter-stack inline parser, one rendering walk. Its output matched `cmark` 0.31.2 byte for byte in differential fuzzing on the supported subset. |
| [`tmpl`](tmpl) | A Jinja-style template engine: expressions, filters, `if`/`for`/`set`/`macro`, `include`, `extends`/`block`/`super()`, whitespace control. |
| [`toml`](toml) | Reader for the TOML subset used by `site.toml` and front matter. |
| `sitegen` (this directory) | The content model and generator built on the three above. |
| [`cmd/sitegen`](cmd/sitegen) | The command-line tool. |

## Build

Requires Go 1.27 or later.

```sh
./build.sh            # builds bin/sitegen
# or directly:
go build -o bin/sitegen ./cmd/sitegen
```

## Command line

```sh
sitegen <input directory> <output directory>
# or, without installing:
./run.sh <input directory> <output directory>
```

The output directory is created if it does not exist. The program reads
nothing but the input directory and writes only into the output directory. It
exits with status 0 on success, 1 if the site cannot be generated (an error
message goes to stderr) and 2 on a usage error.

### Input layout

```
site.toml                 required
content/posts/*.md        posts (optional directory)
content/pages/*.md        pages (optional directory)
templates/*.html          index.html, post.html, page.html, tag.html, tags.html
                          (required) plus any helper templates
static/**                 copied verbatim (optional directory)
```

`site.toml` must define `title`, `base_url` (no trailing `/`), `author` and
`posts_per_page` (an integer ≥ 1). Other keys are passed to templates
unchanged as `site.<key>`.

A content file starts with front matter delimited by `+++` lines, then the
Markdown body:

```
+++
title = "Hello, world"
date = "2024-01-10"          # posts only, YYYY-MM-DD
tags = ["Meta", "Intro"]     # posts only, optional
slug = "hello"               # optional; defaults to the file name without .md
draft = false                # optional; drafts are excluded entirely
+++
The **first** post.
```

### Output

| File | Template |
|------|----------|
| `index.html`, `page/N/index.html` | `index.html` (variables `posts`, `pagination`) |
| `posts/<slug>/index.html` | `post.html` (`post`) |
| `<page slug>/index.html` | `page.html` (`page`) |
| `tags/index.html` | `tags.html` |
| `tags/<tag slug>/index.html` | `tag.html` (`tag`, `posts`) |
| `feed.xml`, `sitemap.xml` | generated |
| everything under `static/` | copied |

Every template also receives `site`, `tags` (tag links) and `pages` (page
links). Posts are ordered newest first (ties by slug); `post.older` and
`post.newer` are the neighbours in that order. The full description of the
objects and of the template language is in the doc comments of packages
`sitegen` and `tmpl`.

A minimal template set:

```html
{# templates/base.html #}
<!doctype html>
<title>{% block title %}{{ site.title }}{% endblock %}</title>
{% block body %}{% endblock %}

{# templates/index.html #}
{% extends "base.html" %}
{% block body %}
{% for post in posts %}<h2><a href="{{ post.url }}">{{ post.title }}</a></h2>
{{ post.excerpt }}{% endfor %}
{% if pagination.has_next %}<a href="{{ pagination.next_url }}">older</a>{% endif %}
{% endblock %}
```

## Library

Generate a site from Go:

```go
package main

import (
	"log"
	"os"

	"example.com/sitegen"
)

func main() {
	site, err := sitegen.Load(os.DirFS("mysite")) // reads and converts everything
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("%d posts, %d tags", len(site.Posts), len(site.Tags))

	if err := site.Generate(sitegen.DirSink("public")); err != nil {
		log.Fatal(err) // includes template errors, with the page being rendered
	}
}
```

`Load` takes any `io/fs.FS` and `Generate` writes to any `Sink`, so sites can
be built in memory (`sitegen.MemSink`) as well as on disk.

The converters work without the generator:

```go
html := markdown.ToHTML("Some *emphasis* and a [link](/x).\n")

set := tmpl.NewSet()
set.Add("hello", `Hello {{ name|upper }}{% if n > 1 %}s{% endif %}!`)
out, err := set.Render("hello", map[string]tmpl.Value{"name": "world", "n": int64(2)})
// out == "Hello WORLDs!"
```

Template values are `string`, `int64`, `float64`, `bool`, `tmpl.None`,
`[]tmpl.Value` and `*tmpl.Dict`. Failures are `*tmpl.Error` values whose
`Kind` is one of `KindSyntax`, `KindFilter`, `KindUndefined`, `KindTemplate`
and `KindType`.

## Tests

```sh
go test ./...
go test -bench . ./...      # converter and renderer benchmarks
```

`testdata/pond` is the worked example of the specification, checked file by
file in `sitegen_test.go`. The unit tests of `markdown` and `tmpl` include the
worked examples of their specifications and cases for every construct; the
large-input tests guard against quadratic behaviour.

## Design notes

- **Everything is converted once.** Each body and excerpt goes through the
  Markdown converter exactly once, however many pages and the feed show it;
  post, page, tag and link objects are built once and shared between pages
  (only `pagination` is built per index page).
- **Tags** are collected in O(K + T log T): posts are visited once in
  canonical order and appended to their tags' lists, so no tag needs a scan or
  sort of posts.
- **Templates** are lexed, parsed and checked at most once per `tmpl.Set`, and
  only when first needed; rendering is a tree walk over scope chains with O(1)
  scope creation and values shared rather than copied.
- **Markdown** uses doubly linked node lists so wrapping and removing inline
  nodes is O(1) per node, cmark's backtick memo for code spans and
  `openers_bottom` bounds for emphasis, keeping every stage linear.
