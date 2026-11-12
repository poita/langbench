# sitegen

A small static site generator written in Haskell. It reads a site directory
(configuration, Markdown content, templates, static files) and writes a
complete website: an index with pagination, post pages, standalone pages, tag
pages, an Atom feed and a sitemap.

Everything the generator needs is implemented in this package, using only
GHC's bundled libraries (`base`, `text`, `containers`, `bytestring`,
`directory`, `filepath`, `array`, `mtl`/`transformers`):

* a **Markdown** converter for a CommonMark subset whose output is
  byte-for-byte what `cmark` 0.31 produces;
* a **template engine** for a Jinja2 subset (`if`/`for`/`set`/`macro`,
  `include`, `extends`/`block`/`super()`, whitespace control, thirteen
  filters);
* a reader for the **TOML subset** used by `site.toml` and front matter.

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
cabal build            # library + executable
./build.sh             # same, and copies the executable to bin/sitegen
cabal test             # the hspec test suite
```

## Command line

```
sitegen <input directory> <output directory>
```

`run.sh` is a wrapper that runs `bin/sitegen` from any working directory:

```sh
./run.sh mysite public
```

The input directory looks like this:

```
site.toml                 title, base_url, author, posts_per_page (+ any extra keys)
content/posts/*.md        posts   (TOML front matter between +++ lines, then Markdown)
content/pages/*.md        pages
templates/*.html          index, post, page, tag, tags (+ any partials/layouts)
static/**                 copied verbatim
```

A post:

```
+++
title = "Hello, world"
date = "2024-01-10"
tags = ["Meta"]
+++
The **first** post.
```

The output directory receives `index.html`, `page/N/index.html`,
`posts/<slug>/index.html`, `<page-slug>/index.html`, `tags/index.html`,
`tags/<tag-slug>/index.html`, `feed.xml`, `sitemap.xml` and the static files.
Drafts (`draft = true`) are excluded everywhere. The output is deterministic:
the feed's `updated` time is the newest post's date, never the clock.

The exit status is 0 on success; any problem (a missing key, a template
error) is reported on stderr with a non-zero status.

Templates receive `site`, `tags` and `pages` always, plus `posts` and
`pagination` (index), `post`, `page`, or `tag` and `posts` (tag pages). The
exact shape of each object is specified in `problems/sitegen/SPEC.md`.

## Library

The package exposes its parts as modules, so each can be used on its own.

| Module | Purpose |
|--------|---------|
| `Sitegen` | `generate`, `generateSite`, `loadSource`, `writeOutput` |
| `Sitegen.Markdown` | `markdownToHtml`, plus the block/inline AST |
| `Sitegen.Template` | `mkTemplates`, `renderTemplate`, `Value` |
| `Sitegen.Toml` | `parseToml` |
| `Sitegen.Content` | front matter, posts, pages, slugs, dates |
| `Sitegen.Site` | configuration, ordering, tags, pagination, URLs |
| `Sitegen.Feed` | `renderFeed`, `renderSitemap` |

Internals live in `Sitegen.Markdown.{Block,Inline,Html,Escape,Types}` and
`Sitegen.Template.{Lexer,Parser,Syntax,Value,Ops,Eval}`.

### Example

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.Text.IO as T
import Sitegen.Markdown (markdownToHtml)
import Sitegen.Template

main :: IO ()
main = do
  -- Markdown to HTML
  T.putStr (markdownToHtml "Hello, *world*!\n")
  -- <p>Hello, <em>world</em>!</p>

  -- Templates: a set of named sources, rendered with some variables.
  let templates = mkTemplates
        [ ("base.html", "<h1>{% block title %}{% endblock %}</h1>")
        , ("page.html", "{% extends \"base.html\" %}{% block title %}{{ title|upper }}{% endblock %}")
        ]
  print (renderTemplate templates "page.html" [("title", VString "hi")])
  -- Right "<h1>HI</h1>"
```

Generating a whole site in memory:

```haskell
import Sitegen

main :: IO ()
main = do
  src <- loadSource "mysite"              -- reads site.toml, content/, templates/
  case generate src of                    -- pure: no files are touched
    Left err    -> putStrLn err
    Right files -> writeOutput "public" files >> copyStatic "mysite" "public"
```

Parsed templates are cached inside the `Templates` value: each template is
lexed, parsed and checked at most once, however many pages are rendered.
Likewise each post's body and excerpt are converted to HTML at most once and
shared by every page and the feed that shows them.

## Design notes

* **Markdown** follows cmark's two phases. The block parser is a line-driven
  walk over the chain of open blocks (mutable tree in `ST`, frozen into the
  pure `Block` type); the inline parser keeps a delimiter stack and a bracket
  stack over a mutable linked list of nodes, so wrapping and removal cost O(1)
  per node moved. Code-span search uses cmark's backtick memo and emphasis
  uses `openers_bottom`, so pathological input stays linear.
* **Templates** are lexed and parsed to a tree once, then interpreted. Scopes
  are mutable (in `ST`) because a `set` is visible to macros defined earlier in
  the same scope; values are immutable and shared, so passing and binding them
  is O(1).
* **Model**: tags are collected in one pass over the (post, tag) pairs; post,
  page and tag objects are built once and shared by every context that
  contains them.

## Tests

`cabal test` runs an hspec suite (with a few QuickCheck properties) covering
the TOML reader, the Markdown converter (including the reference examples), the
template language (every operator, filter and error kind), content handling,
the site model, the feed and sitemap, and a complete generation of the example
site from the specification.
