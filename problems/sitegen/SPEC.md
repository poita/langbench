# sitegen — static site generator

Read a source site directory (configuration, Markdown content, templates and
static files) and write a complete static website into an output directory.

Write the Markdown converter, the template engine and the TOML-subset reader
yourself: don't use a Markdown, template or TOML implementation from a library,
the standard library or the language.

This is a **directory-mode** problem. The program is invoked with exactly two
arguments:

```
<command> <input directory> <output directory>
```

The input directory is the site source. The output directory already exists
and is empty (an implementation may also create it if it is missing); the
program creates files and subdirectories inside it and writes nothing
anywhere else. Nothing is read from stdin; anything written to stdout or
stderr is ignored. The exit code must be 0.

All text is UTF-8 with LF (`\n`) line endings and no byte-order mark. All
output text files are written as UTF-8 with LF line endings.

Every input in the test suite is valid as described here. An implementation
may do anything at all on an input that violates this specification — the
tests never contain one — but it must not fail on a valid input.

## Contents

1. [Input layout](#input-layout)
2. [The TOML subset](#the-toml-subset)
3. [site.toml](#sitetoml)
4. [Content files](#content-files)
5. [Markdown](#markdown)
6. [Templates](#templates)
7. [The content model](#the-content-model)
8. [Context variables](#context-variables)
9. [Output layout](#output-layout)
10. [feed.xml](#feedxml)
11. [sitemap.xml](#sitemapxml)
12. [Static files](#static-files)
13. [Worked example](#worked-example)
14. [Guarantees](#guarantees)
15. [Architecture and size](#architecture-and-size)

## Input layout

```
<input>/
    site.toml                 required
    content/
        posts/*.md            zero or more posts       (directory may be absent)
        pages/*.md            zero or more pages       (directory may be absent)
    templates/*.html          required; see "Templates"
    static/**                 copied verbatim          (directory may be absent)
```

- Only regular files **directly inside** `content/posts` and `content/pages`
  whose name ends with `.md` are content files. Any other entry in those two
  directories is ignored. The tests contain no such entry.
- Only regular files directly inside `templates` whose name ends with `.html`
  are templates. Any other entry is ignored; the tests contain none.
- `static` may contain arbitrarily nested subdirectories and files of any
  kind, text or binary.
- No other entry of the input directory is read.

## The TOML subset

`site.toml` and the front matter of every content file are written in the
following small subset of TOML. A full TOML parser is not needed and must not
be assumed: the tests only ever use this subset.

A document is a sequence of lines separated by LF. Each line is one of:

- **Blank**: empty, or containing only spaces and tabs. Ignored.
- **Comment**: its first character that is not a space or tab is `#`. Ignored.
- **Assignment**: `key = value`, described below.

There are no tables, no table headers (`[name]`), no dotted keys, no
multi-line values and no multi-line strings.

### Assignments

An assignment line matches

```
[ \t]* KEY [ \t]* = [ \t]* VALUE ( [ \t]* ( # comment ) )?
```

- `KEY` is one or more characters from `A-Z a-z 0-9 _ -`.
- After `VALUE`, the rest of the line must be spaces and tabs, optionally
  followed by `#` and arbitrary text (a comment). A `#` inside a string is
  part of the string, not a comment.
- Keys are recorded in the order in which they appear. A key never repeats in
  one document.

### Values

| Form | Meaning |
|------|---------|
| `"..."` | **String** (TOML basic string) |
| `123`, `-4`, `0` | **Integer**: an optional `-`, then either `0` or a nonzero digit followed by digits. No `+`, no underscores, no leading zeros, no hex/octal/binary forms. |
| `true`, `false` | **Boolean** |
| `["a", "b"]` | **Array of strings** |

A **basic string** starts and ends with `"` on the same line. Between the
quotes, a `\` introduces exactly one of these escapes; any other character
(including `#`, `'` and non-ASCII characters) stands for itself, and a
literal `"` or `\` must be escaped:

| Escape | Character |
|--------|-----------|
| `\"` | `"` |
| `\\` | `\` |
| `\n` | LF (U+000A) |
| `\t` | TAB (U+0009) |
| `\r` | CR (U+000D) |
| `\uXXXX` | the code point with that four-hex-digit value (hex digits may be upper or lower case) |

An **array** is `[`, then zero or more basic strings separated by `,`, then
`]`, all on one line. Spaces and tabs may appear after `[`, around each `,`
and before `]`. A single trailing `,` before `]` is allowed. Arrays of any
other element type, and nested arrays, never occur.

Examples:

```toml
# a comment
title  = "The \"Big\" Blog"        # trailing comment
posts_per_page = 5
draft = false
tags = ["one", "two",]
motto = "line one\nline two"
```

parses to `title` = `The "Big" Blog`, `posts_per_page` = `5`, `draft` =
`false`, `tags` = `["one", "two"]`, `motto` = `"line one\nline two"`.

## site.toml

`site.toml` is a TOML-subset document. These four keys are always present:

| Key | Type | Meaning |
|-----|------|---------|
| `title` | string | the site title |
| `base_url` | string | the site's absolute base URL, **without** a trailing `/` (e.g. `https://example.com`, or `https://example.com/blog`) |
| `author` | string | the default author name, used in `feed.xml` |
| `posts_per_page` | integer ≥ 1 | how many posts appear on one index page |

Any other keys may also be present; they are passed through to templates
unchanged. The whole parsed document, in file order, is the `site` variable
available to every template (see "Context variables").

## Content files

A content file is a Markdown file that begins with TOML-subset front matter:

```
+++
<TOML subset lines>
+++
<Markdown body>
```

- The first four bytes of the file are exactly `+++\n`.
- The front matter ends at the first later line that is exactly `+++` (three
  `+` and nothing else). The delimiter is a **whole line**: a `+++` that is
  part of a longer line, or that sits inside a front-matter string value,
  ends nothing, and `+++` lines in the body are ordinary text.
- The **body** is everything after that line's LF, verbatim. If the closing
  `+++` is the last line of the file the body is the empty string.

### Post front matter (`content/posts/*.md`)

| Key | Type | Required | Default |
|-----|------|----------|---------|
| `title` | string | yes | — |
| `date` | string `YYYY-MM-DD` | yes | — |
| `slug` | string | no | the file name with the trailing `.md` removed |
| `tags` | array of strings | no | `[]` |
| `draft` | boolean | no | `false` |

### Page front matter (`content/pages/*.md`)

| Key | Type | Required | Default |
|-----|------|----------|---------|
| `title` | string | yes | — |
| `slug` | string | no | the file name with the trailing `.md` removed |
| `draft` | boolean | no | `false` |

Pages never carry `date` or `tags`.

A content file with `draft = true` is **excluded completely**: it produces no
output file, appears in no list, in no feed and in no sitemap, and its tags do
not exist unless some published post also carries them.

Dates are always well-formed: four digits, `-`, two digits, `-`, two digits,
denoting a real calendar date. They are compared and sorted as plain strings,
which for this format is the same as chronological order.

## Markdown

A body is converted to HTML by **the CommonMark subset specified in
`../commonmark/SPEC.md`** (relative to this file:
`problems/commonmark/SPEC.md`). That document is the normative definition of
the conversion: it describes exactly what `cmark` 0.31.2 with default options
produces for the subset, and its expected outputs were produced by `cmark`.
The conversion here is the same function: given the body text, it returns the
HTML string, which for a non-empty document ends with a newline and for an
empty document is the empty string.

The supported constructs are thematic breaks, ATX headings, setext headings,
indented code blocks, fenced code blocks, paragraphs, blank lines, block
quotes, list items and lists, backslash escapes, entity references, code
spans, emphasis and strong emphasis, inline links and images, autolinks, hard
line breaks, soft line breaks and textual content. HTML blocks, raw inline
HTML, link reference definitions and all extensions (tables, strikethrough,
footnotes, …) are **not** supported and never occur.

Every body in every test satisfies all of the guarantees in
`../commonmark/SPEC.md` §"What the input never contains". Restated here so
that an implementer needs nothing beyond that document:

1. Valid UTF-8, no BOM, no NUL, no CR, no DEL and no control character other
   than TAB and LF.
2. **No HTML.** Every `<` immediately followed by an ASCII letter, `/`, `!`
   or `?` is either the start of a valid autolink, or on a line belonging to
   a fenced or indented code block, or inside a code span or inside the
   `<...>` destination of an inline link or image that parses successfully
   (and in that last case it is never the first non-blank character of a
   line's content). So no HTML block ever starts and no raw inline HTML ever
   occurs.
3. **No link reference definitions**: no line of any block begins with a link
   label followed by `:`. `[text]` not followed by `(` is always literal text.
4. **Named entities**: other than `&amp;`, `&lt;`, `&gt;` and `&quot;`, no
   `&name;` in a body is a valid HTML5 named character reference.
5. **Delimiter neighbours**: a character immediately before or after a run of
   `*` or of `_` is never a non-ASCII whitespace, punctuation, symbol or
   control character, so only the ASCII flanking rules are needed.
6. No run of backticks is longer than 100 and no code fence is longer than
   100 characters.
7. **Empty list items**: when a list item's first line contains nothing after
   the marker, the following line is either non-blank or, after removing
   block quote prefixes, completely empty.

Because the generated HTML is inserted into templates without escaping (see
"Templates"), the Markdown output appears verbatim in the generated pages.

## Templates

Templates are rendered by **the Jinja subset specified in
`../template/SPEC.md`** (relative to this file:
`problems/template/SPEC.md`). That document is the normative definition of the
template language: its expected outputs were produced by Jinja2 3.1 with
`StrictUndefined`, `trim_blocks=False`, `lstrip_blocks=False` and autoescape
**off**, and it describes exactly what Jinja2 does on the supported subset.

The language, in one paragraph: `{{ expr }}` prints, `{% ... %}` is a
statement, `{# ... #}` is a comment; `-` next to a delimiter trims adjacent
whitespace; statements are `if`/`elif`/`else`/`endif`, `for`/`else`/`endfor`
(with `loop.index`, `loop.index0`, `loop.first`, `loop.last`, `loop.length`),
`set`, `macro`/`endmacro`, `include`, `extends`, `block`/`endblock` with
`super()`; expressions have the usual operators plus the thirteen filters
`upper`, `lower`, `trim`, `escape`, `replace`, `length`, `int`, `join`,
`first`, `last`, `reverse`, `sort`, `default`. Read `../template/SPEC.md` for
the exact semantics of each of them; nothing here changes them.

Two things are adapted to this problem:

- **Names.** The templates available to `include` and `extends` are the
  `.html` files directly inside `templates/`, named by their **file name
  including the extension**: `{% extends "base.html" %}`,
  `{% include "nav.html" %}`. Template names never contain a `/`.
- **Source text.** A template's source is the file's contents with **one
  trailing LF removed** if the file ends with one. (This matches Jinja2's
  default `keep_trailing_newline=False` and the `=== name` convention of
  `../template/SPEC.md`.) A file consisting of `hi\n` is the one-line
  template `hi`; a file ending with two LFs is a template ending with one LF.

These five templates are always present; each is the entry point for a kind
of page:

| Template | Renders |
|----------|---------|
| `index.html` | `index.html` and every `page/N/index.html` |
| `post.html` | every `posts/<slug>/index.html` |
| `page.html` | every `<page-slug>/index.html` |
| `tag.html` | every `tags/<tag-slug>/index.html` |
| `tags.html` | `tags/index.html` |

Any further `.html` files in `templates/` are available to `include` and
`extends` but are never entry points. A template that no rendering ever loads
is never parsed and never checked (it may even be invalid, though the tests
contain no such file).

Rendering one page means: create a root scope holding exactly the variables
listed for that template in the next section, then render the entry-point
template in it, exactly as `../template/SPEC.md` describes rendering "the
first template" with the JSON context as the root scope. The resulting string
is the file's contents, written verbatim with no trailing newline added.

Every rendering in the tests succeeds: no template in any test produces any
of the `syntax`, `filter`, `undefined`, `template` or `type` errors of
`../template/SPEC.md`, and every test template satisfies that document's
guarantees.

## The content model

### Slugs

The **slug of a tag** is derived from its name by:

1. mapping each of `A`–`Z` to the corresponding lower-case letter;
2. replacing every character that is not `a`–`z` or `0`–`9` with `-`;
3. collapsing every run of two or more `-` into a single `-`;
4. removing a leading `-` and a trailing `-`.

So `"Web Development"` → `web-development`, `"C++"` → `c`, `"Rust 2024"` →
`rust-2024`.

Post and page slugs are **not** transformed: they are used exactly as given
(by the `slug` key or by the file name). In the tests every post slug, page
slug and tag slug consists only of `a`–`z`, `0`–`9` and `-`, is non-empty, and
does not start or end with `-`.

### Posts

The **published posts** are the `content/posts/*.md` files without
`draft = true`. Their **canonical order** is:

- by `date` **descending** (newest first; string comparison, which equals
  chronological order for `YYYY-MM-DD`);
- ties broken by `slug` **ascending**, comparing the slugs as sequences of
  Unicode code points.

This order is used for the index pages, the feed, the sitemap, the tag pages
and the older/newer links. Post slugs are unique within a site.

### Pages

The **published pages** are the `content/pages/*.md` files without
`draft = true`, ordered by `slug` ascending (code point order). Page slugs are
unique within a site and never equal `posts`, `page` or `tags`.

### Tags

A tag **exists** iff at least one published post lists it. Tag identity is the
exact tag **name** (case-sensitive, compared as a code point sequence). Within
one post's `tags` array, a repeated name is dropped, keeping the first
occurrence; the remaining order is the front-matter order.

The **tag list** of the site is every existing tag name, ordered by **slug
ascending** (code point order). No two distinct tag names in a test share a
slug.

A tag's **posts** are the published posts that list it, in canonical order.
Its **post count** is how many there are.

### Long dates

`date_long` renders `YYYY-MM-DD` as `<Month> <D>, <YYYY>` using the English
month names `January February March April May June July August September
October November December`, the day **without** a leading zero, and the year
as the four digits given. `2024-03-05` → `March 5, 2024`; `1999-12-25` →
`December 25, 1999`.

### URLs

All of these are site-root-relative paths that begin and end with `/`:

| Object | `url` |
|--------|-------|
| index page 1 | `/` |
| index page N > 1 | `/page/N/` (N in decimal, no padding) |
| post | `/posts/<post slug>/` |
| page | `/<page slug>/` |
| tag index | `/tags/` |
| tag | `/tags/<tag slug>/` |

A `permalink` is `base_url` followed by the `url`, i.e. simple string
concatenation. With `base_url = "https://example.com"` a post's permalink is
`https://example.com/posts/hello/`.

### Content and excerpt

- **`content`**, a member of both the post and the page object, is the
  Markdown conversion of the whole body, verbatim.
- **`excerpt`**, a member of the post object only, is the Markdown conversion
  of the body's **first block**: skip the body's leading blank lines (lines
  containing only spaces and tabs), then take the following maximal run of
  non-blank lines, join them with LF, and convert that. A body that is
  entirely blank has the empty excerpt.

For a body that begins with an ordinary paragraph the excerpt is that
paragraph's `<p>…</p>`. For a body beginning with `# Title` it is the
`<h1>` element alone. The rule is purely textual: it knows nothing about
Markdown structure, so a first block that is a fenced code block containing a
blank line is cut at that blank line and the excerpt contains an unclosed
fence (which the converter closes at the end of the document).

## Context variables

Values are the value kinds of `../template/SPEC.md`: strings, integers,
booleans, `none`, lists and dicts. A **dict** here is an insertion-ordered
mapping with the members listed, in the order listed. The tests never print a
dict or a list directly, so only member access and iteration matter.

### Object shapes

**tag link** — a tag without its posts:

| Member | Type |
|--------|------|
| `name` | string — the tag name as written |
| `slug` | string |
| `url` | string — `/tags/<slug>/` |
| `post_count` | integer — the tag's site-wide post count, the same value wherever this tag appears |

**post link** — a post without its body, used for older/newer navigation:

| Member | Type |
|--------|------|
| `title`, `slug`, `url`, `permalink`, `date`, `date_long` | strings |

**page link** — a page for a navigation menu:

| Member | Type |
|--------|------|
| `title`, `slug`, `url` | strings |

**post** — the full post object:

| Member | Type |
|--------|------|
| `title` | string |
| `slug` | string |
| `url` | string — `/posts/<slug>/` |
| `permalink` | string |
| `date` | string — `YYYY-MM-DD` |
| `date_long` | string |
| `tags` | list of **tag link**, in the post's own tag order |
| `content` | string — HTML |
| `excerpt` | string — HTML |
| `older` | **post link** of the next post in canonical order (the older one), or `none` for the last post |
| `newer` | **post link** of the previous post in canonical order (the newer one), or `none` for the first post |

`older` and `newer` are neighbours in the **site-wide** canonical order of all
published posts. They do not change with the list a post appears in: the same
post object, with the same `older` and `newer`, is used on its own page, on an
index page and inside a tag's `posts`, even when the neighbour is not itself a
member of that list.

**page** — the full page object:

| Member | Type |
|--------|------|
| `title`, `slug`, `url`, `permalink` | strings |
| `content` | string — HTML |

**tag** — the full tag object (a tag link plus its posts):

| Member | Type |
|--------|------|
| `name`, `slug`, `url` | strings |
| `post_count` | integer |
| `posts` | list of **post**, in canonical order |

**pagination**:

| Member | Type |
|--------|------|
| `number` | integer — the current index page, 1-based |
| `total_pages` | integer — at least 1 |
| `total_posts` | integer — published posts in the whole site |
| `has_prev` | boolean — `number > 1` |
| `has_next` | boolean — `number < total_pages` |
| `prev_url` | string — the previous index page's url, or `none` when `number == 1` |
| `next_url` | string — the next index page's url, or `none` when `number == total_pages` |
| `links` | list of dicts `{number, url, current}`, one per index page, `number` from 1 to `total_pages`, `current` true for exactly the current one |

### Variables per template

Three variables are in the root scope of **every** rendering:

| Variable | Value |
|----------|-------|
| `site` | dict — the parsed `site.toml`, keys in file order, values as parsed |
| `tags` | list of **tag link**, in tag-list order (by slug) |
| `pages` | list of **page link**, in page order (by slug) |

In addition:

| Template | Extra variables |
|----------|-----------------|
| `index.html` | `posts` — list of **post**: the slice of the canonical order belonging to this index page (`posts_per_page` of them, fewer on the last page, empty when the site has no posts); `pagination` |
| `post.html` | `post` — the **post** |
| `page.html` | `page` — the **page** |
| `tag.html` | `tag` — the full **tag**; `posts` — the same list as `tag.posts` |
| `tags.html` | (none beyond the three shared ones) |

No other name is bound. Reading any other name is an `undefined` error in the
sense of `../template/SPEC.md`, and the tests never do it.

## Output layout

Let `P` be `posts_per_page`, `n` the number of published posts and

```
total_pages = max(1, ceil(n / P))
```

so a site with no posts still has exactly one index page. The output directory
receives, and receives only:

| Path | Produced by |
|------|-------------|
| `index.html` | `index.html` with index page 1 |
| `page/2/index.html` … `page/<total_pages>/index.html` | `index.html` with index page N (omitted when `total_pages == 1`) |
| `posts/<post slug>/index.html` | `post.html`, one per published post |
| `<page slug>/index.html` | `page.html`, one per published page |
| `tags/index.html` | `tags.html` |
| `tags/<tag slug>/index.html` | `tag.html`, one per existing tag |
| `feed.xml` | see below |
| `sitemap.xml` | see below |
| every file under `static/` | copied, see below |

Index page N (1-based) shows the posts at positions `(N-1)*P` through
`N*P - 1` of the canonical order.

Directories are created as needed. Empty directories need not be created.
Nothing else is written.

No two of these paths are ever equal (guarantee 3 below makes every post,
page and tag slug a non-empty `[a-z0-9-]` string, and a page slug is never
`posts`, `page` or `tags`), so the order in which the files are written never
matters.

## feed.xml

An Atom 1.0 feed, written exactly in the following layout: one element per
line, two spaces of indentation per level, LF line endings, and a final LF.
Entries are the **first `posts_per_page` posts** of the canonical order (all
of them when there are fewer).

```
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>TEXT(site.title)</title>
  <id>TEXT(base_url + "/")</id>
  <updated>UPDATED</updated>
  <link href="ATTR(base_url + "/")" rel="alternate"/>
  <link href="ATTR(base_url + "/feed.xml")" rel="self"/>
  <author>
    <name>TEXT(site.author)</name>
  </author>
  <entry>
    <title>TEXT(post.title)</title>
    <id>TEXT(post.permalink)</id>
    <updated>post.date + "T00:00:00Z"</updated>
    <link href="ATTR(post.permalink)" rel="alternate"/>
    <content type="html">TEXT(post.content)</content>
  </entry>
  ... one <entry> block per post, in canonical order ...
</feed>
```

- `TEXT(s)` replaces, in this order, `&` with `&amp;`, `<` with `&lt;` and
  `>` with `&gt;`. `ATTR(s)` is `TEXT(s)` with `"` further replaced by
  `&quot;`. No other character is escaped, and `'` is never escaped.
- **`UPDATED` is fixed by this rule** so that the output is deterministic and
  never depends on the clock: it is the `date` of the newest published post
  (the first in canonical order) followed by `T00:00:00Z`; when the site has
  no published posts it is exactly `1970-01-01T00:00:00Z`.
- A post's `content` normally ends with a newline, so the `<content>` element
  usually spans several lines and its closing tag starts a line. That is
  intended: the content is inserted verbatim after escaping, with no
  re-indentation and no trimming.
- When there are no entries, the `<author>` block is immediately followed by
  `</feed>`.

## sitemap.xml

```
<?xml version="1.0" encoding="utf-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>TEXT(absolute url)</loc>
  </url>
  ...
</urlset>
```

with a final LF, two spaces of indentation per level, and one `<url>` block
for each of the following, **in this order**:

1. the index pages, `base_url + "/"` then `base_url + "/page/2/"` … up to
   `total_pages`;
2. every published post, in canonical order — these blocks carry a second
   child line `    <lastmod>post.date</lastmod>` after the `<loc>` line;
3. every published page, in page order;
4. the tag index, `base_url + "/tags/"`;
5. every tag, in tag-list order.

Only post entries have `<lastmod>`.

## Static files

Every **file** under `static/`, at any depth — including files and
directories whose name begins with `.`, and files of zero length — is copied
byte for byte to the output directory at the same relative path:
`static/css/site.css` becomes `<output>/css/site.css`, and
`static/robots.txt` becomes `<output>/robots.txt`. The `static/` component itself is dropped. Text and
binary files alike are copied unchanged; no newline translation or
re-encoding happens. Empty directories under `static/` produce nothing.

In the tests, no static file's destination ever collides with a generated
page, feed or sitemap.

## Worked example

Input tree:

```
site/site.toml
site/content/posts/hello-world.md
site/content/posts/on-ducks.md
site/content/pages/about.md
site/templates/base.html
site/templates/index.html
site/templates/post.html
site/templates/page.html
site/templates/tag.html
site/templates/tags.html
site/static/robots.txt
```

`site.toml`:

```toml
title = "Pond Notes"
base_url = "https://pond.example"
author = "R. Duck"
posts_per_page = 1
```

`content/posts/hello-world.md`:

```
+++
title = "Hello, world"
date = "2024-01-10"
tags = ["Meta"]
+++
The **first** post.

More text.
```

`content/posts/on-ducks.md`:

```
+++
title = "On Ducks"
date = "2024-02-01"
tags = ["Birds", "Meta"]
slug = "ducks"
+++
Ducks are *fine*.
```

`content/pages/about.md`:

```
+++
title = "About"
+++
# About

Nothing here.
```

`templates/base.html`:

```
<!doctype html>
<title>{% block title %}{{ site.title }}{% endblock %}</title>
{% block body %}{% endblock %}
```

`templates/index.html`:

```
{% extends "base.html" %}
{% block body %}{% for post in posts %}<h2><a href="{{ post.url }}">{{ post.title }}</a></h2>
{{ post.excerpt }}{% endfor %}<p>page {{ pagination.number }} of {{ pagination.total_pages }}</p>
{% if pagination.has_next %}<a href="{{ pagination.next_url }}">older</a>{% endif %}{% endblock %}
```

`templates/post.html`:

```
{% extends "base.html" %}
{% block title %}{{ post.title }} · {{ site.title }}{% endblock %}
{% block body %}<article>
{{ post.content }}</article>
<p>{{ post.date_long }}{% for t in post.tags %} <a href="{{ t.url }}">{{ t.name }}</a>{% endfor %}</p>
{% if post.older %}<a href="{{ post.older.url }}">{{ post.older.title }}</a>{% endif %}{% endblock %}
```

`templates/page.html`:

```
{% extends "base.html" %}
{% block title %}{{ page.title }}{% endblock %}
{% block body %}{{ page.content }}{% endblock %}
```

`templates/tag.html`:

```
{% extends "base.html" %}
{% block body %}<h1>{{ tag.name }} ({{ tag.post_count }})</h1>
<ul>{% for post in posts %}<li>{{ post.title }}</li>{% endfor %}</ul>{% endblock %}
```

`templates/tags.html`:

```
{% extends "base.html" %}
{% block body %}<ul>{% for t in tags %}<li><a href="{{ t.url }}">{{ t.name }}</a> {{ t.post_count }}</li>{% endfor %}</ul>{% endblock %}
```

Output tree:

```
index.html
page/2/index.html
posts/ducks/index.html
posts/hello-world/index.html
about/index.html
tags/index.html
tags/birds/index.html
tags/meta/index.html
feed.xml
sitemap.xml
robots.txt
```

`index.html` (canonical order is `ducks`, then `hello-world`; `P` = 1):

```
<!doctype html>
<title>Pond Notes</title>
<h2><a href="/posts/ducks/">On Ducks</a></h2>
<p>Ducks are <em>fine</em>.</p>
<p>page 1 of 2</p>
<a href="/page/2/">older</a>
```

`posts/ducks/index.html`:

```
<!doctype html>
<title>On Ducks · Pond Notes</title>
<article>
<p>Ducks are <em>fine</em>.</p>
</article>
<p>February 1, 2024 <a href="/tags/birds/">Birds</a> <a href="/tags/meta/">Meta</a></p>
<a href="/posts/hello-world/">Hello, world</a>
```

`tags/index.html` (tag links ordered by slug: `birds`, `meta`):

```
<!doctype html>
<title>Pond Notes</title>
<ul><li><a href="/tags/birds/">Birds</a> 1</li><li><a href="/tags/meta/">Meta</a> 2</li></ul>
```

`feed.xml` (`posts_per_page` is 1, so one entry):

```
<?xml version="1.0" encoding="utf-8"?>
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
```

`sitemap.xml`:

```
<?xml version="1.0" encoding="utf-8"?>
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
```

## Guarantees

Beyond the Markdown and template guarantees restated above, every test input
satisfies all of the following.

1. The input directory exists and contains `site.toml` and `templates/` with
   at least the five required templates. `site.toml` has the four required
   keys with the stated types, `posts_per_page` ≥ 1, and `base_url` is a
   non-empty string that does not end with `/`.
2. Every content file has well-formed front matter with its required keys of
   the stated types, and a valid `YYYY-MM-DD` date on every post.
3. Post slugs are unique among published posts, page slugs are unique among
   published pages, and tag slugs are unique among existing tags. Post, page
   and tag slugs match `[a-z0-9]([a-z0-9-]*[a-z0-9])?`. A page slug is never
   `posts`, `page` or `tags`.
4. No `static/` file's output path collides with a generated file.
5. Names used in templates as dict members (`site` keys included) are never
   any of `items keys values get pop update copy clear count index append`
   and never begin with an underscore; no template binds a variable named
   `range`, `super`, `loop`, `self`, `varargs`, `kwargs` or `caller`.
6. `site.toml` values are strings, integers, booleans or arrays of strings;
   no site key is named `posts`, `pagination`, `post`, `page`, `tag` or
   `tags`.
7. Content and template files contain no CR. Static files may contain
   anything, including NUL bytes.
8. Every `.md` file in `content/posts` and `content/pages` has a `.md`
   extension and a name that is a valid file name on any platform; content
   file names are only ever used for the default slug.
9. Every integer in a TOML-subset document fits in a signed 64-bit integer,
   and no `\uXXXX` escape denotes a surrogate code point (U+D800–U+DFFF), so
   every parsed string is a sequence of Unicode scalar values.

## Architecture and size

A complete implementation has four parts:

1. **A CommonMark-subset converter** — the largest part; see
   `../commonmark/SPEC.md`. Roughly 1000–1500 lines: a line-driven block
   parser, a delimiter-stack inline parser and an HTML renderer.
2. **A Jinja-subset template engine** — see `../template/SPEC.md`. Roughly
   800–1200 lines: a tag lexer, a Pratt/precedence expression parser, a
   statement parser producing a tree, and a tree-walking renderer with
   scopes, macros, includes and block inheritance.
3. **A TOML-subset parser and the content model** — a few hundred lines:
   front matter splitting, slugs, dates, ordering, tag collection,
   pagination.
4. **The generator** — a few hundred lines: building the context dicts,
   rendering each page, emitting `feed.xml` and `sitemap.xml`, copying
   `static/`.

Total: roughly three to five thousand lines in a typical systems language.
The two sub-languages are specified in their own documents and are worth
implementing (and testing) first.

## Limits and performance

The site with the most posts has 313 of them, 35 tags, 2 pages and 225 KB of
Markdown, and produces 387 output files and about 1 MB of HTML. The site with
the most text has 85 posts and 1.1 MB of Markdown, the largest single body
being 34 KB. Every other site is much smaller. Templates are at most a few
kilobytes each, and no site has more than nine of them.

The Python reference implementation processes every site in well under a
second; a compiled implementation should be faster still. A per-test limit of
120 seconds is ample.
