# sitegen

A small static site generator written in Clojure with no runtime dependencies
beyond Clojure itself.  It reads a site source directory — configuration,
Markdown content with TOML front matter, Jinja-style templates and static
files — and writes a complete website: an index with pagination, post, page
and tag pages, an Atom feed and a sitemap.

The three languages involved are implemented from scratch, as separate and
independently usable library modules:

| Module                    | What it is                                                               |
|---------------------------|--------------------------------------------------------------------------|
| `sitegen.markdown`        | CommonMark subset → HTML, matching `cmark` 0.31.2 byte for byte          |
| `sitegen.template`        | Jinja2-subset template engine (inheritance, macros, filters, …)          |
| `sitegen.toml`            | Reader for the TOML subset used by `site.toml` and front matter          |
| `sitegen.content`         | Content files: front-matter splitting and the post/page schemas          |
| `sitegen.model`           | Ordering, tags, slugs, dates, pagination and the template-facing objects |
| `sitegen.feed`            | `feed.xml` (Atom 1.0) and `sitemap.xml`                                  |
| `sitegen.render`          | Renders a model through the templates into output files                  |
| `sitegen.io`              | Reading the source tree, writing files, copying `static/`                |
| `sitegen.core`            | The public entry points: `generate!` and `build-site`                    |
| `sitegen.main`            | The command-line tool                                                    |

## Requirements

Java and the [Clojure CLI](https://clojure.org/guides/install_clojure)
(`clojure`).  The project is developed with Clojure 1.12.6 on Java 27.

## Building

```sh
./build.sh
```

`build.sh` AOT-compiles the command-line tool into `classes/` and records the
runtime classpath in `target/classpath`; it can be run from any directory.
The AOT-compiled tool starts in a fraction of a second, which matters because
the generator is run once per site build.

## Command-line usage

```sh
./run.sh <input directory> <output directory>
```

The output directory is created if it does not exist.  Nothing is read from
standard input.  The exit status is 0 on success, 1 if generation failed (the
reason is printed on standard error) and 2 on a usage error.

### Input layout

```
<input>/
    site.toml                 required: title, base_url, author, posts_per_page
    content/
        posts/*.md            posts   (optional directory)
        pages/*.md            pages   (optional directory)
    templates/*.html          index, post, page, tag and tags are required
    static/**                 copied verbatim (optional directory)
```

A content file starts with TOML front matter between `+++` lines:

```
+++
title = "Hello, world"
date  = "2024-01-10"          # posts only
tags  = ["Meta"]              # posts only
slug  = "hello"               # optional; defaults to the file name
draft = false                 # drafts are excluded completely
+++
The **first** post.
```

Templates are Jinja2-style (`{{ }}`, `{% if/for/set/macro/include/extends/block %}`,
`super()`, whitespace control and the filters `upper lower trim escape replace
length int join first last reverse sort default`).  Each entry-point template
receives `site`, `tags` and `pages` plus `posts` and `pagination` (index),
`post`, `page`, or `tag` and `posts` (tag pages).

### Output layout

```
index.html, page/N/index.html      index pages (posts_per_page posts each)
posts/<slug>/index.html            one per published post
<page-slug>/index.html             one per published page
tags/index.html, tags/<slug>/index.html
feed.xml, sitemap.xml
<everything under static/>
```

The output is deterministic: it never depends on the clock, and the feed's
`<updated>` is the date of the newest post.

## Using the library

Add the project as a `:local/root` (or git) dependency and require the modules
you need.

```clojure
(require '[sitegen.core :as sitegen]
         '[sitegen.markdown :as md]
         '[sitegen.template :as tpl]
         '[sitegen.toml :as toml])

;; Generate a whole site.
(sitegen/generate! "my-site" "public")

;; Or build it in memory: a map from output path to file text.
(sitegen/build-site
  {:config    "title = \"T\"\nbase_url = \"https://e.org\"\nauthor = \"A\"\nposts_per_page = 5\n"
   :posts     [["hello.md" "+++\ntitle = \"Hi\"\ndate = \"2024-03-05\"\n+++\nHello *world*\n"]]
   :pages     []
   :templates {"index.html" "{% for p in posts %}{{ p.title }} ({{ p.date_long }}){% endfor %}"
               "post.html"  "{{ post.content }}"
               "page.html"  "{{ page.content }}"
               "tag.html"   "{{ tag.name }}"
               "tags.html"  "{{ tags|length }} tags"}})
;; => {"index.html" "Hi (March 5, 2024)", "posts/hello/index.html" "<p>Hello <em>world</em></p>\n", ...}

;; The modules also work on their own.
(md/->html "# Title\n\nSome *emphasis*.")
;; => "<h1>Title</h1>\n<p>Some <em>emphasis</em>.</p>\n"

(def env (tpl/make-env {"greeting" "Hello {{ name|upper }}!"}))
(tpl/render env "greeting" {"name" "ada"})
;; => "Hello ADA!"

(into {} (toml/parse-document "n = 3\ntags = [\"a\", \"b\"]"))
;; => {"n" 3, "tags" ["a" "b"]}
```

Template errors are thrown as `ex-info`; `(tpl/error-kind e)` returns `:syntax`,
`:filter`, `:undefined`, `:template` or `:type`.  Template values are plain
JVM values: `Long`, `Double`, `Boolean`, `nil`, `String`, `java.util.List` and
`java.util.Map` (use a `LinkedHashMap` where member order matters).

## Design

The generator is a four-stage pipeline — *load*, *model*, *render*, *emit* —
with each stage in its own namespace and no hidden state.

* **Markdown** follows cmark's two-phase design.  `markdown.block` is a
  line-driven block parser that matches each line against the chain of open
  blocks; `markdown.inline` scans paragraph text with a delimiter stack and a
  bracket stack (code spans use cmark's backtick memo, emphasis uses
  `openers_bottom`, so all of it is linear); `markdown.html` renders the tree
  with one iterative walk, so nesting depth is bounded by the heap, not the
  stack.  The parser's mutable node tree is private to a conversion
  (`sitegen.mutable` provides the small `defmutable` macro it is built on).
* **Templates** are lexed and parsed once per environment into a syntax tree
  and executed by a tree-walking interpreter over lexical scopes.  Values are
  shared rather than copied, so passing a large list or dict is O(1).
* **The model** builds every post, page and tag object (and every link to one)
  exactly once, converts each body and excerpt to HTML exactly once (in
  parallel), and collects tags in O(K + T log T).

## Testing

```sh
clojure -M:test
```

runs the `clojure.test` suites in `test/` with the Cognitect test-runner.
They include example-based tests for every module, `test.check` properties
(for instance: Markdown conversion is total, the template operators agree with
Clojure's, floats print so that they round-trip), fixtures whose expected
HTML was produced by `cmark` (`test-resources/markdown`), and an end-to-end
test of the worked example from the specification (`test-resources/sample-site`).
