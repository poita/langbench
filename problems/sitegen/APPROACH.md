# sitegen: required approach

SPEC.md defines what the output must be; this note defines how the program
computes it. Where the two seem to disagree, SPEC.md wins.

Sizes: `P` published posts, `G` pages, `T` tags, `K` (post, tag) pairs, `I`
index pages, `N` bytes of Markdown, `W` template nodes executed over the run.

## Algorithm

A pipeline in four stages:

1. **Load:** read `site.toml`, every content file and every template; parse
   front matter with a line-based parser for the TOML subset.
2. **Model:** sort posts and pages, collect the tags, convert every body and
   excerpt to HTML, and build the template values (site, tag, page and post
   objects and links, pagination links).
3. **Render:** for each output page, bind those values into a root scope and
   render its template.
4. **Emit:** write `feed.xml` and `sitemap.xml` from the model and copy
   `static/`.

The Markdown converter is the one `problems/commonmark/APPROACH.md` describes
and the template engine the one `problems/template/APPROACH.md` describes,
including their required rules.

## Required rules

1. **Each body and each excerpt is converted to HTML once**, however many pages
   and the feed show it.
2. **Collecting tags is O(K + T log T)**: no scan of every post for each tag.
3. **Post, page and tag objects and links are built once** and shared wherever
   they appear; only each index page's `pagination` is built per page.

## Complexity

O(N + P log P + G log G + K + T log T + I² + W + total output). Template
rendering (`W`) dominates on template-heavy sites.
