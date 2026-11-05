# sitegen

`sitegen` is a small static site generator written in Go with no dependencies
outside the standard library. It reads a source directory — a `site.toml`,
Markdown content with TOML front matter, Jinja-style templates and static
files — and writes a complete website: a paginated index, one page per post and
page, tag pages, an Atom feed, a sitemap and a copy of the static files.

Everything that would normally come from a library is implemented here:

| Package | What it is |
|---------|------------|
| `example.com/sitegen/toml` | the TOML subset used by `site.toml` and front matter |
| `example.com/sitegen/markdown` | a CommonMark-subset converter that follows `cmark` 0.31.2 |
| `example.com/sitegen/tmpl` | a Jinja2-subset template engine (inheritance, macros, filters, strict undefined) |
| `example.com/sitegen` | the content model, template values, feed, sitemap and output writer |
| `cmd/sitegen` | the command-line tool, a thin wrapper over the library |

## Build

Requires Go 1.27.1 or later.

```sh
./build.sh          # builds bin/sitegen
go test ./...       # runs the unit tests
```

`build.sh` and `run.sh` work from any current directory.

## Command line

```
sitegen <input directory> <output directory>
# or, without installing:
./run.sh <input directory> <output directory>
```

The input directory is the site source (layout below); the generated site is
written into the output directory, which is created if it does not exist.
Nothing is read from standard input. The exit status is 0 on success; on any
error a message goes to standard error and the status is 1 (2 for a usage
error).

### Source layout

```
site.toml                 title, base_url, author, posts_per_page (+ any other keys)
content/posts/*.md        posts   (title, date "YYYY-MM-DD"; optional slug, tags, draft)
content/pages/*.md        pages   (title; optional slug, draft)
templates/*.html          index, post, page, tag and tags are required
static/**                 copied verbatim
```

A content file starts with front matter between `+++` lines, followed by the
Markdown body:

```
+++
title = "On Ducks"
date = "2024-02-01"
tags = ["Birds", "Meta"]
+++
Ducks are *fine*.
```

### Output

| File | Rendered with |
|------|---------------|
| `index.html`, `page/N/index.html` | `index.html` (`posts`, `pagination`) |
| `posts/<slug>/index.html` | `post.html` (`post`) |
| `<page-slug>/index.html` | `page.html` (`page`) |
| `tags/index.html` | `tags.html` |
| `tags/<tag-slug>/index.html` | `tag.html` (`tag`, `posts`) |
| `feed.xml`, `sitemap.xml` | generated |
| everything under `static/` | copied |

Every template also sees `site` (the parsed `site.toml`), `tags` and `pages`.
Posts are ordered newest first (ties by slug), drafts are skipped everywhere,
and tag slugs are derived from tag names (`"Web Development"` →
`web-development`). Templates use `{{ expr }}`, `{% if/for/set/macro/include/
extends/block %}`, `{# comments #}`, whitespace control with `-`, and the
filters `upper lower trim escape replace length int join first last reverse
sort default`. Output is not auto-escaped; using an undefined variable is an
error.

## Library

Build a site from a directory or from any `fs.FS`:

```go
package main

import (
	"log"

	"example.com/sitegen"
)

func main() {
	out, err := sitegen.BuildDir("mysite") // or sitegen.Build(fsys)
	if err != nil {
		log.Fatal(err)
	}
	for _, f := range out.Files {
		log.Println(f.Path, len(f.Data))
	}
	if err := out.WriteDir("public"); err != nil {
		log.Fatal(err)
	}
}
```

`Load` / `Site.Generate` split the same work in two steps, which is useful for
inspecting the content model (`Site.Posts`, `Site.Pages`, `Site.Tags`) before
rendering.

The building blocks are usable on their own:

```go
import (
	"example.com/sitegen/markdown"
	"example.com/sitegen/tmpl"
	"example.com/sitegen/toml"
)

html := markdown.ToHTML("# Hi\n\nSome *emphasis*.\n")

doc, _ := toml.Parse("title = \"Hello\"\nn = 3\n")
title, _ := doc.String("title")

e := tmpl.New()
e.Add("base.html", "<h1>{% block title %}{% endblock %}</h1>")
e.Add("page.html", `{% extends "base.html" %}{% block title %}{{ name|upper }}{% endblock %}`)
ctx := tmpl.NewDict()
ctx.Set("name", "ada")
out, err := e.Render("page.html", ctx) // "<h1>ADA</h1>"
```

Template errors are `*tmpl.Error` values whose `Kind` is one of `SyntaxError`,
`FilterError`, `UndefinedError`, `TemplateError` or `TypeError`.

## Testing

`go test ./...` runs the unit tests of every package. The Markdown package is
checked against golden files in `markdown/testdata`, whose expected HTML was
produced by `cmark` 0.31.2. The `sitegen` package builds in-memory sites with
`testing/fstest`.

## Design notes

* The pipeline is single-threaded: load everything, build the content model and
  every template value once (dicts and lists are shared by reference wherever
  they appear), render each page into memory, write each file with one write.
* The Markdown converter mirrors `cmark`: a line-driven block parser, a
  delimiter-stack inline parser with the "rule of 3", and an iterative renderer
  (so deeply nested emphasis cannot overflow the stack).
* The template engine parses each template once into an AST (cached by name,
  loaded lazily), resolves operators and filters at parse time, and interprets
  the tree with small linearly-searched scopes. `Engine` is not safe for
  concurrent use.
