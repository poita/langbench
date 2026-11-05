# sitegen — implementation approach

SPEC.md defines what the output must be. This note fixes how the program
computes it. Below, P is the number of published posts, G of pages, T of tags,
K the total number of (post, tag) pairs, I the number of index pages, N the
total Markdown size in bytes and W the number of template nodes and expressions
evaluated over the whole run.

## Overall approach

A single-threaded pipeline in four stages. (1) Load: read `site.toml`, every
content file and every template whole; parse front matter with a line-based
TOML-subset parser. (2) Model: sort posts and pages once, collect tags in
one pass, convert every body and excerpt to HTML once, and build every
template value (site dict, tag links, page links, post links, post, page
and tag objects, pagination link dicts) exactly once as shared, immutable
values. (3) Render: for each output page, bind the shared values into a
fresh root scope and run the template engine of
`problems/template/APPROACH.md` (templates parsed once into a cached AST, a
tree-walking interpreter, one output buffer), then write the file with one
write. (4) Emit `feed.xml` and `sitemap.xml` from the model into one buffer
each, and copy `static/`.

## Required choices

1. **Single thread, sequential output.** No threads, processes or async
   I/O. Each output file is produced in full in memory and written with a
   single open/write/close. Each output directory is created once (the
   program knows which directories it creates: `page/<n>/`, `posts/<slug>/`,
   `<page-slug>/`, `tags/<slug>/`, and the directories found under
   `static/`), not by a recursive "make all parents" call per file.
2. **Markdown.** Use the converter described in
   `problems/commonmark/APPROACH.md` (one in-memory pass per document, O(n)
   in the body size). Each post body is converted exactly twice, once for
   `content` and once for its excerpt source (the first block, found by one
   scan of the body's lines); each page body once. `feed.xml` reuses the
   stored `content` strings. Total O(N).
3. **Template engine.** Implement `problems/template/APPROACH.md` in full:
   lazily loaded and cached templates with an AST, dispatch on a kind tag,
   parse-time operator/filter codes and attribute keys, shared-reference
   values, insertion-ordered dicts with a hash index, macros holding their
   defining scope, block chains, include and blocks appending to the current
   buffer, and macro/`super()` rendering into a fresh buffer. On top of that,
   this problem fixes the options that note leaves open: every scope below
   the root, and the root scope too (it holds at most five names here), is a
   small array of (name, value) bindings searched linearly; names are
   resolved by walking the scope chain at run time (no compile-time slot
   resolution); `loop` is one small loop record per execution of a `for`
   statement, updated in place each iteration (never a five-member dict, and
   never allocated per iteration).
4. **Content model.** Sort posts once by (date descending, slug ascending,
   comparing bytes) and pages once by slug: O(P log P + G log G). Drop
   repeated tag names within each post first. Then collect tags in one pass
   over the posts in canonical order with a hash map from tag name to tag
   record, appending each post to its tags' post lists as it goes, so each
   tag's posts come out already in canonical order; then sort the tags by
   slug. Slugs, URLs, permalinks and `date_long` are computed once per
   object. Total O(K + T log T).
5. **Shared context values.** Every tag link, page link, post link, post
   object, page object and tag object is built once before rendering and
   referenced from everywhere it appears: the `tags` and `pages` lists, each
   post's `tags`, `older`/`newer`, index-page slices, `tag.posts` (which is
   the same list value as the tag page's `posts`). An index page's `posts`
   is a list of references to existing post objects. For
   `pagination.links`, build for each page number n two link dicts once
   (`current` false and true, sharing one `url` string) and give each index
   page a list of I references to them; only the `pagination` dict and that
   list are new per index page. Construction is O(P + G + T + K + I²)
   references with O(P + G + T + I) dicts; no dict or string is built per
   rendered page except those.
6. **Feed and sitemap.** Built by appending to one growable buffer, with
   the TEXT/ATTR escapers scanning once and copying unescaped runs in bulk;
   written once. O(output size).
7. **Static files.** Walk `static/` recursively (including names beginning
   with `.`); copy each file by reading it whole and writing it whole, or by
   one OS-level file copy.

Overall the run is O(N + P log P + K + T log T + I² + W + total output
bytes) time. On the template-heavy input W dominates: hundreds of thousands
of loop iterations, each with a handful of name lookups, member accesses,
comparisons and some macro calls, so the per-iteration constant (allocations
per iteration, cost of a lookup) is what items 3 and 5 fix.

## Left to the implementer

- Container types, struct/record layout, naming and module structure.
- Whether names and keys are interned; whether scopes come from a pool or
  arena; whether page output buffers are reused across pages.
- Whether a macro call that is printed directly streams into the output
  instead of building a temporary string (output is the same).
- Error-reporting mechanism (exceptions, result values); the tests never
  produce an error.
- The order in which output files are produced.
- Micro-optimisations: integer formatting, pre-sizing buffers, ASCII fast
  paths in `length`, subscripts and `lower`/`upper`.

## Pitfalls

- Representing every scope as a hash map, and allocating a fresh hash map
  (plus a fresh `loop` dict with its own hash index and freshly allocated
  key strings) on every loop iteration: on the pager and rail loops this
  multiplies template time by two to three.
- A value type that holds its string by value, so every variable read,
  member access, list iteration or argument pass copies the text (post
  `content` strings are tens of KB); or copying a list before iterating it.
- Building a temporary string for the attribute name on each `a.NAME`
  access.
- Dispatching on node or expression kind through a sequence of dynamic
  casts / type tests instead of one switch on a kind tag.
- Reference cycles between a scope and a macro value bound in it (the macro
  holds that scope) under reference counting: each rendering leaks its
  scopes and values, and memory grows by hundreds of MB over the run. Break
  the cycle (a weak reference to the defining scope, clearing the template
  scope when its rendering ends, or a rendering-scoped arena).
- Rebuilding post objects, tag links or pagination link dicts per rendered
  page, re-converting Markdown for the feed, or rebuilding URL and date
  strings on every use.
- Finding each tag's posts by scanning every post for every tag, or
  looking up tag records by linear search over all tags.
- Indexing a string (`t.slug[0]`) by first materialising it as a list of
  one-character strings.
- Re-parsing a template on every `include`/`extends`/render, or caching
  only its source text.
- Building page output by repeated concatenation of immutable strings
  (quadratic), or issuing one write per node.
