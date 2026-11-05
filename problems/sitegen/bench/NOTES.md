# sitegen benchmark inputs

`gen_bench.py` builds these sites with fixed seeds from the public-domain corpora in
`../corpus`. Expected trees come from `reference/main.py`. They are checked with the
same oracles `gen_tests.py` uses: tomllib for every TOML document, cmark 0.31.2 for
every body and excerpt, and Jinja2 for every rendered page. The script also applies
every SPEC guarantee check. Expected bytes plus input bytes come to about 29.7 MB.

SPEC "Limits and performance" describes the public tests: at most 313 posts and
1.1 MB of Markdown. These sites are larger on purpose. They still keep to every
format rule and guarantee, use at most nine templates of a few KB each, and keep
every body at or below about 50 KB. On macOS, about 0.1–0.2 ms per output file is
kernel file-creation time, the same for every language. Inputs 001 and 003 write
1.4k and 2.6k files, so part of their time is this fixed I/O cost.

- `001_blog_archive_1200_posts`: a 20-year technical blog with 1200 posts of 0.6–3 KB.
  It has about 3% drafts, 60 Zipf-distributed tags, 8 pages and 60 static files (some
  binary). It uses a production theme: layout, nav and sidebar includes, macros and a
  windowed pager. This measures end-to-end throughput on an ordinary large site:
  front matter, Markdown, templating, feed/sitemap and file output, all in normal
  proportions.
- `002_long_reads_markdown_heavy`: 230 long essays of 16–50 KB (4.1 MB of Markdown).
  Most are inline-dense: nested emphasis, links and images with titles, code spans,
  autolinks, entities, escapes and hard breaks. They also have deep nested lists,
  nested block quotes and fenced code. The theme is the lean archive theme and the
  site writes only about 300 files, so the CommonMark converter (the algorithmically
  hardest part) dominates. The 30 MB budget limits this input: output roughly equals
  input in size. As a result the fastest compiled implementations take about 0.2 s,
  not 0.3 s.
- `003_magazine_template_heavy`: a news magazine with 1800 short stories, 3 per page
  (600 index pages), and 180 tags. The theme does a lot of template work: card macros
  with keyword arguments and filters on every story, a windowed pager that scans every
  page link on each of the 600 index pages, and a rail that scans all 180 tags on
  every page. Tag pages list their stories, and the topic index is an A–Z scan. This
  measures the Jinja-subset interpreter (scopes, loops, macro calls, filters) on a
  realistic mixed site, with little extra output per unit of work.

## Long tier

There is no long tier. The compiled implementations' wall time on these sites
is mostly kernel file creation (for example Go on 001: 0.68 s wall, 0.06 s user,
0.32 s sys for 1,420 files), so wall time grows with the number and size of
output files. Reaching 5-7 s would need roughly 20,000-35,000 output files and
several hundred MB of expected output per site, beyond the on-disk budget.
Even 003's quadratic pager scan does not help, because each extra index page
is itself another output file.
