#!/usr/bin/env python3
"""Generates the sitegen performance benchmark in bench/ (same layout as tests/).

Each case is bench/NNN_name/input (a site source tree) and
bench/NNN_name/expected (the output tree written by reference/main.py). All
text is derived deterministically, with fixed seeds, from the vendored
public-domain corpora in ../corpus, so re-running this script reproduces the
benchmark exactly.

Every input is checked with the same guarantee checks gen_tests.py applies to
the public tests (Markdown subset guarantees, slug/collision/site-key
guarantees, well-formed feed and sitemap). Unless --no-oracles is given, every
TOML document is re-parsed with tomllib, every body and excerpt is
re-converted with cmark 0.31.2, and every rendered page is re-rendered with
Jinja2 (from ../../../.oracle-venv when present), exactly as gen_tests.py does.

    python3 gen_bench.py [--no-oracles]
"""
import datetime
import os
import random
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)
sys.dont_write_bytecode = True

import gen_tests as gt  # noqa: E402  (importing only defines helpers and themes)

ref = gt.ref

# $LANGBENCH_ORACLE_PYTHON overrides; otherwise the oracle venv lives in the main checkout, and a worktree may not
# have its own.
if not os.path.exists(gt.VENV_PYTHON):
    for candidate in (os.environ.get('LANGBENCH_ORACLE_PYTHON', ''),
                      os.path.normpath(os.path.join(PROBLEM, '..', '..', '..', '..', '..',
                                                    '.oracle-venv', 'bin', 'python'))):
        if os.path.exists(candidate):
            gt.VENV_PYTHON = candidate
            break


# ---------------------------------------------------------------------------
# Text sources
# ---------------------------------------------------------------------------

FORBIDDEN = set('[]*_`<>&\\#|{}')


def sentence_pool():
    """Prose sentences from the three corpora, free of Markdown-active characters."""
    out = []
    for name in ('aesop.txt', 'bacon.txt', 'federalist.txt'):
        text = gt.read_corpus(name)
        for para in gt.paragraphs(text):
            flat = ' '.join(para.split())
            for s in re.split(r'(?<=[.?!;])\s+', flat):
                if 30 <= len(s) <= 320 and not (set(s) & FORBIDDEN) and not s[0].isdigit():
                    out.append(s)
    return out


SENTENCES = sentence_pool()
WORDS = sorted({w for s in SENTENCES for w in re.findall(r'\b[a-z]{3,12}\b', s)})
ALPHA = re.compile(r'^[A-Za-z]+$')

TECH_WORDS = ('server client request response buffer parser token stream module function '
              'value config cache index query schema record field option handler thread '
              'process memory output input runtime compiler linker allocator scheduler '
              'iterator closure generic trait borrow channel socket kernel shader vector '
              'matrix tensor graph queue heap stack mutex atomic future promise lambda').split()
IDENTS = ['parse_args', 'read_config', 'HttpClient', 'max_retries', 'user_id', 'on_error',
          'BufferPool', 'open_stream', 'timeout_ms', 'is_valid', 'get_or_insert',
          'std::string', 'map[string]int', '__init__', 'self.items', 'ctx.Done()', 'len(xs)',
          'x->next', 'a && b', 'i < n', '--verbose', '--output=out.html', '$HOME/.config',
          '0x7fff', '#include', '*ptr', '**kwargs', 'foo_bar_baz', 'i <= 0', 'a -> b']
LANGS = ['python', 'rust', 'go', 'cpp', 'd', 'js', 'bash', 'toml', 'json', 'sql', '', '']
SITES = ['https://example.com', 'https://docs.example.org', 'http://localhost:8080',
         'https://github.com/example/repo', 'https://en.wikipedia.org/wiki',
         'https://api.example.net/v2', 'https://www.gutenberg.org/ebooks']


def url(rng):
    path = '/'.join(rng.choice(WORDS) for _ in range(rng.randint(0, 3)))
    u = rng.choice(SITES) + '/' + path
    r = rng.random()
    if r < 0.15:
        u += '?q=%s&page=%d' % (rng.choice(WORDS), rng.randint(1, 50))
    elif r < 0.25:
        u += '#' + rng.choice(WORDS)
    elif r < 0.30:
        u += '.html'
    return u


def word(rng):
    return rng.choice(TECH_WORDS) if rng.random() < 0.3 else rng.choice(WORDS)


# ---------------------------------------------------------------------------
# Inline decoration
# ---------------------------------------------------------------------------

def emph_run(rng, toks, dense):
    """Wraps a run of plain words in emphasis, sometimes nested."""
    d = rng.choice(['*', '**', '_', '__', '*', '**'] + (['***'] if dense else []))
    if dense and len(toks) >= 3 and rng.random() < 0.4:
        inner_d = '_' if d.startswith('*') else '*'
        k = rng.randint(1, len(toks) - 1)
        toks = toks[:k] + [inner_d + toks[k] + inner_d] + toks[k + 1:]
    return d + ' '.join(toks) + d


def decorate(rng, sentence, density, dense=False):
    """Inserts inline constructs into a plain prose sentence.

    Emphasis delimiters are only placed against ASCII letters on the inside
    and a space or ASCII punctuation on the outside, so the ASCII-only
    flanking guarantee of the Markdown subset holds.
    """
    toks = sentence.split(' ')
    out = []
    i = 0
    while i < len(toks):
        t = toks[i]
        r = rng.random()
        if r >= density or not ALPHA.match(t):
            out.append(t)
            i += 1
            continue
        r = rng.random()
        if r < 0.30:
            n = 1
            while (n < 4 and i + n < len(toks) and ALPHA.match(toks[i + n])
                   and rng.random() < 0.5):
                n += 1
            out.append(emph_run(rng, toks[i:i + n], dense))
            i += n
            continue
        if r < 0.45:
            n = rng.randint(1, 3)
            text = ' '.join(toks[i:i + n])
            if dense and rng.random() < 0.3:
                text = '*' + toks[i] + '*' + (' ' + ' '.join(toks[i + 1:i + n]) if n > 1 else '')
            title = rng.choice(['', '', ' "%s %s"' % (word(rng), word(rng)), " '%s'" % word(rng),
                                ' (%s)' % word(rng)])
            bang = '!' if rng.random() < 0.08 else ''
            out.append('%s[%s](%s%s)' % (bang, text, url(rng), title))
            i += n
            continue
        if r < 0.62:
            ident = rng.choice(IDENTS) if rng.random() < 0.7 else t
            if '`' in ident:
                ident = t
            if dense and rng.random() < 0.15:
                out.append('`` `%s` ``' % ident)
            else:
                out.append('`%s`' % ident)
            out.append(t)
            i += 1
            continue
        if r < 0.67:
            out.append('<%s>' % url(rng))
            out.append(t)
            i += 1
            continue
        if r < 0.74:
            out.append(rng.choice(['&amp;', '&#8212;', '&#x2014;', '&quot;', '&lt;', '&gt;',
                                   '&#169;', 'AT&T']))
            out.append(t)
            i += 1
            continue
        if r < 0.80:
            out.append(rng.choice(['\\*', '\\_', '\\[', '\\]', '\\#', '\\`', '\\\\', '\\&']) + t)
            i += 1
            continue
        if r < 0.86 and dense:
            out.append(rng.choice(['snake_case_name', 'a_b_c', '2*3*4', 'x**2', 'foo*bar*baz',
                                   '__dunder__']))
            out.append(t)
            i += 1
            continue
        out.append(t)
        i += 1
    return ' '.join(out)


BLOCK_START = set('-+*#>=_`~0123456789<[!&|:')


def wrap(rng, text, width, hard_breaks=0.0):
    lines, cur = [], ''
    for tok in text.split(' '):
        if not tok:
            continue
        if cur and len(cur) + 1 + len(tok) > width:
            lines.append(cur)
            cur = tok
        else:
            cur = cur + ' ' + tok if cur else tok
    if cur:
        lines.append(cur)
    fixed = []
    for ln in lines:
        if ln[0] in BLOCK_START:
            ln = rng.choice(WORDS) + ' ' + ln
        fixed.append(ln)
    if hard_breaks:
        for k in range(len(fixed) - 1):
            if rng.random() < hard_breaks:
                fixed[k] += rng.choice(['  ', '\\'])
    return fixed


def prose(rng, nsent, density, dense=False):
    return ' '.join(decorate(rng, rng.choice(SENTENCES), density, dense) for _ in range(nsent))


def paragraph(rng, nsent, density, dense=False, width=78):
    return wrap(rng, prose(rng, nsent, density, dense), width, 0.06 if dense else 0.0)


# ---------------------------------------------------------------------------
# Block generators
# ---------------------------------------------------------------------------

def code_lines(rng, lo=3, hi=18):
    out = []
    indent = 0
    for _ in range(rng.randint(lo, hi)):
        r = rng.random()
        if r < 0.15 and indent < 12:
            out.append(' ' * indent + 'fn %s(%s: &%s) -> Result {'
                       % (rng.choice(WORDS), word(rng), rng.choice(['str', '[u8]', 'Config'])))
            indent += 4
        elif r < 0.27 and indent:
            indent -= 4
            out.append(' ' * indent + '}')
        elif r < 0.31:
            out.append('')
        else:
            out.append(' ' * indent + 'let %s = %s(%s) && x < 10; // %s *not* _%s_'
                       % (word(rng), rng.choice(IDENTS), word(rng), word(rng), word(rng)))
    while out and out[-1] == '':
        out.pop()
    return out or ['pass']


def fenced(rng, pad=''):
    fence = rng.choice(['```', '```', '~~~', '````'])
    return ([pad + fence + rng.choice(LANGS)] + [pad + ln if ln else '' for ln in code_lines(rng)]
            + [pad + fence])


def md_list(rng, depth, density, dense, max_depth):
    ordered = rng.random() < 0.35
    bullet = rng.choice('-*+')
    loose = rng.random() < 0.25
    start = rng.choice([1, 1, 1, 3, 10]) if ordered and depth == 0 else 1
    out = []
    for i in range(rng.randint(2, 7 if not dense else 9)):
        marker = '%d.' % (start + i) if ordered else bullet
        pad = ' ' * (len(marker) + 1)
        para = paragraph(rng, rng.randint(1, 2), density, dense, 70)
        out.append(marker + ' ' + para[0])
        out.extend(pad + ln for ln in para[1:])
        if depth < max_depth and rng.random() < (0.35 if dense else 0.2):
            if loose:
                out.append('')
            out.extend(pad + ln if ln else '' for ln in md_list(rng, depth + 1, density, dense,
                                                                max_depth))
        elif rng.random() < (0.1 if dense else 0.05):
            out.append('')
            out.extend(fenced(rng, pad))
        if loose and i:
            out.append('')
    while out and out[-1] == '':
        out.pop()
    return out


def blockquote(rng, density, dense, depth=0):
    inner = paragraph(rng, rng.randint(1, 4), density, dense)
    if rng.random() < 0.4:
        inner[0] = '**Note:** ' + inner[0]
    out = ['> ' + ln for ln in inner]
    r = rng.random()
    if r < 0.3:
        out.append('>')
        out.extend(('> ' + ln) if ln else '>' for ln in md_list(rng, 1, density, dense, 2))
    elif r < 0.4 and depth < 2:
        out.append('>')
        out.extend(('> ' + ln) if ln else '>' for ln in blockquote(rng, density, dense, depth + 1))
    elif r < 0.5:
        out.append('>')
        out.extend(('> ' + ln) if ln else '>' for ln in fenced(rng))
    return out


def heading(rng, level, density, dense):
    words = [rng.choice(WORDS) for _ in range(rng.randint(2, 6))]
    words[0] = words[0].capitalize()
    text = decorate(rng, ' '.join(words), density * 0.6, dense)
    if text[0] in BLOCK_START:
        text = 'On ' + text
    if rng.random() < 0.12:
        return [text, '=' * len(text) if level == 1 else '-' * len(text)]
    return ['#' * level + ' ' + text]


def body(rng, target, density, dense=False, structure=1.0, lead=(2, 4)):
    """A post body of about `target` bytes of mixed Markdown."""
    blocks = [paragraph(rng, rng.randint(*lead), density, dense)]
    size = sum(len(x) + 1 for x in blocks[0])
    last = 'p'
    while size < target:
        r = rng.random() / structure if structure else 1.0
        if r < 0.08:
            b, kind = heading(rng, rng.choice([2, 2, 3]), density, dense), 'h'
        elif r < 0.20:
            b, kind = md_list(rng, 0, density, dense, 3 if dense else 2), 'l'
        elif r < 0.28:
            b, kind = fenced(rng), 'c'
        elif r < 0.35:
            b, kind = blockquote(rng, density, dense), 'q'
        elif r < 0.38 and last == 'p':
            b, kind = ['    ' + ln for ln in code_lines(rng, 2, 8) if ln], 'i'
        elif r < 0.40:
            b, kind = [rng.choice(['---', '***', '* * *', '___'])], 't'
        elif r < 0.42:
            b, kind = ['![%s %s](/img/%s.png "%s")' % (word(rng), word(rng), word(rng),
                                                       word(rng))], 'p'
        else:
            b, kind = paragraph(rng, rng.randint(2, 7), density, dense), 'p'
        grow = sum(len(x.encode('utf-8')) + 1 for x in b) + 1
        if size + grow > target * 1.25:
            break
        blocks.append(b)
        last = kind
        size += grow
    return '\n\n'.join('\n'.join(b) for b in blocks) + '\n'


def title(rng, lo=2, hi=7):
    words = [rng.choice(WORDS) for _ in range(rng.randint(lo, hi))]
    small = {'the', 'and', 'for', 'with', 'from', 'into', 'upon', 'which'}
    return ' '.join(w if (k and w in small) else w.capitalize() for k, w in enumerate(words))


def zipf_pick(rng, items, k, s=1.1):
    weights = [1.0 / (i + 1) ** s for i in range(len(items))]
    chosen = []
    while len(chosen) < k:
        t = rng.choices(items, weights)[0]
        if t not in chosen:
            chosen.append(t)
    return chosen


def static_tree(spec, rng, nfiles):
    """A realistic static/ directory: CSS, JS, fonts, images, dotfiles."""
    spec.text('static/css/site.css', gt.SITE_CSS * 20)
    spec.text('static/robots.txt', gt.ROBOTS)
    spec.text('static/.well-known/security.txt', 'Contact: mailto:security@example.com\n')
    spec.text('static/.nojekyll', '')
    for k in range(nfiles):
        kind = rng.random()
        if kind < 0.55:
            data = bytes.fromhex('89504e470d0a1a0a') + rng.randbytes(rng.randint(500, 6000))
            spec.binary('static/img/%d/%s-%d.png' % (k % 7, rng.choice(WORDS), k), data)
        elif kind < 0.75:
            lines = ['function %s_%d(x) { return x && %s(x) < %d; }'
                     % (rng.choice(WORDS), j, rng.choice(WORDS), j) for j in range(rng.randint(20, 120))]
            spec.text('static/js/%s-%d.js' % (rng.choice(WORDS), k), '\n'.join(lines) + '\n')
        elif kind < 0.85:
            spec.binary('static/fonts/%s-%d.woff2' % (rng.choice(WORDS), k),
                        b'wOF2\x00\x01\x00\x00' + rng.randbytes(rng.randint(2000, 12000)))
        else:
            spec.text('static/downloads/%s-%d.txt' % (rng.choice(WORDS), k),
                      '\n'.join(rng.choice(SENTENCES) for _ in range(rng.randint(5, 40))) + '\n')


# ---------------------------------------------------------------------------
# Themes
# ---------------------------------------------------------------------------

# A production-style blog theme: shared layout with nav include, a sidebar
# that scans every tag for the popular ones, a windowed pager over all index
# pages, adjacent-post navigation and macros for repeated fragments.
THEME_PORTAL = {
    'base.html': """\
{% macro taglink(t) %}<a class="tag tag-{{ t.slug }}" href="{{ t.url }}">{{ t.name }}</a>{% endmacro -%}
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{% block title %}{{ site.title }}{% endblock %}</title>
<meta name="description" content="{% block description %}{{ site.description }}{% endblock %}">
<link rel="alternate" type="application/atom+xml" href="{{ site.base_url }}/feed.xml">
<link rel="stylesheet" href="/css/site.css">
</head>
<body class="{% block bodyclass %}page{% endblock %}">
<header class="site">
<a class="brand" href="/">{{ site.title }}</a>
{% include "nav.html" %}
</header>
<div class="layout">
<main>
{% block main %}{% endblock %}
</main>
{% include "sidebar.html" %}
</div>
<footer class="site"><p>&copy; {{ site.since }}&ndash;{{ site.year }} {{ site.author }} &middot; {{ pages|length }} pages &middot; {{ tags|length }} topics</p></footer>
</body>
</html>
""",
    'nav.html': """\
<nav>
<ul>
{%- for p in pages %}
<li><a href="{{ p.url }}">{{ p.title }}</a></li>
{%- endfor %}
<li><a href="/tags/">Topics</a></li>
</ul>
</nav>
""",
    'sidebar.html': """\
<aside>
<h2>Popular topics</h2>
<ul class="popular">
{%- for t in tags %}{% if t.post_count >= site.popular_threshold %}
<li>{{ taglink(t) }} <span>{{ t.post_count }}</span></li>
{%- endif %}{% endfor %}
</ul>
<p class="keywords">{{ site.keywords|sort|join(", ") }}</p>
</aside>
""",
    'index.html': """\
{% extends "base.html" %}
{% block title %}{% if pagination.number > 1 %}Page {{ pagination.number }} &middot; {% endif %}{{ site.title }}{% endblock %}
{% block bodyclass %}index{% endblock %}
{% block main %}
{% for post in posts %}
<article class="summary">
<h2><a href="{{ post.url }}">{{ post.title }}</a></h2>
<p class="meta"><time datetime="{{ post.date }}">{{ post.date_long }}</time>{% for t in post.tags %} {{ taglink(t) }}{% endfor %}</p>
{{ post.excerpt }}<p class="more"><a href="{{ post.url }}">Continue reading &rarr;</a></p>
</article>
{% else %}
<p class="empty">Nothing has been written yet.</p>
{% endfor %}
<nav class="pager">
{%- if pagination.has_prev %} <a rel="prev" href="{{ pagination.prev_url }}">Newer</a>{% endif %}
{%- set window = site.pager_window %}
{%- for l in pagination.links %}
{%- if l.current %} <strong>{{ l.number }}</strong>
{%- elif l.number == 1 or l.number == pagination.total_pages or (l.number >= pagination.number - window and l.number <= pagination.number + window) %} <a href="{{ l.url }}">{{ l.number }}</a>
{%- elif l.number == pagination.number - window - 1 or l.number == pagination.number + window + 1 %} &hellip;
{%- endif %}
{%- endfor %}
{%- if pagination.has_next %} <a rel="next" href="{{ pagination.next_url }}">Older</a>{% endif %}
</nav>
<p class="count">Page {{ pagination.number }} of {{ pagination.total_pages }}; {{ pagination.total_posts }} posts in total.</p>
{% endblock %}
""",
    'post.html': """\
{% extends "base.html" %}
{% block title %}{{ post.title }} &middot; {{ site.title }}{% endblock %}
{% block description %}{{ post.title|escape }}{% endblock %}
{% block bodyclass %}post{% endblock %}
{% block main %}
<article class="post">
<h1>{{ post.title }}</h1>
<p class="meta">By {{ site.author }} on <time datetime="{{ post.date }}">{{ post.date_long }}</time></p>
{{ post.content }}{% if post.tags %}<p class="tags">Filed under{% for t in post.tags %} {{ taglink(t) }} ({{ t.post_count }}){% if not loop.last %},{% endif %}{% endfor %}</p>
{% endif %}</article>
<nav class="adjacent">
{%- if post.newer %}
<a class="newer" rel="next" href="{{ post.newer.url }}">&larr; {{ post.newer.title }} <small>{{ post.newer.date_long }}</small></a>
{%- endif %}
{%- if post.older %}
<a class="older" rel="prev" href="{{ post.older.url }}">{{ post.older.title }} <small>{{ post.older.date_long }}</small> &rarr;</a>
{%- endif %}
</nav>
<p class="permalink"><a href="{{ post.permalink }}">{{ post.permalink }}</a></p>
{% endblock %}
""",
    'page.html': """\
{% extends "base.html" %}
{% block title %}{{ page.title }} &middot; {{ site.title }}{% endblock %}
{% block main %}
<article class="page">
{{ page.content }}</article>
<p class="permalink"><a href="{{ page.permalink }}">{{ page.permalink }}</a></p>
{% endblock %}
""",
    'tag.html': """\
{% extends "base.html" %}
{% block title %}{{ tag.name }} &middot; {{ site.title }}{% endblock %}
{% block bodyclass %}tag{% endblock %}
{% block main %}
<h1>Posts about &ldquo;{{ tag.name }}&rdquo;</h1>
<p>{{ tag.post_count }} post{% if tag.post_count != 1 %}s{% endif %}, newest first.</p>
<ul class="postlist">
{%- for post in posts %}
<li><time datetime="{{ post.date }}">{{ post.date }}</time> <a href="{{ post.url }}">{{ post.title }}</a>{% if post.tags|length > 1 %} <small>also in {% for t in post.tags %}{% if t.name != tag.name %}{{ t.name }}{% if not loop.last %}, {% endif %}{% endif %}{% endfor %}</small>{% endif %}</li>
{%- endfor %}
</ul>
{% endblock %}
""",
    'tags.html': """\
{% extends "base.html" %}
{% block title %}Topics &middot; {{ site.title }}{% endblock %}
{% block main %}
<h1>Topics</h1>
<ul class="tagcloud">
{%- for t in tags %}
<li class="w{{ t.post_count * 5 // tags[0].post_count }}">{{ taglink(t) }} <span class="count">{{ t.post_count }}</span></li>
{%- endfor %}
</ul>
<p>{{ tags|length }} topics.</p>
{% endblock %}
""",
}

# A magazine theme leaning hard on the template engine: macros with keyword
# arguments, filters in every card, a windowed pager, sidebars that scan all
# tags and pages on every rendering, and per-post tag summaries.
THEME_MAGAZINE = {
    'layout.html': """\
{% macro chip(label, href, cls="chip") %}<a class="{{ cls }}" href="{{ href }}">{{ label }}</a>{% endmacro -%}
{% macro card(p, show_tags=true) -%}
<div class="card" id="post-{{ p.slug }}">
<h3><a href="{{ p.url }}">{{ p.title|trim }}</a></h3>
<p class="meta">{{ p.date|replace("-", ".") }} &middot; {{ p.date_long }}{% if show_tags and p.tags %} &middot; {% for t in p.tags %}{{ chip(t.name|lower, t.url, cls="chip c" ~ (t.post_count % 7)) }}{% if not loop.last %} {% endif %}{% endfor %}{% endif %}</p>
{{ p.excerpt }}</div>
{%- endmacro -%}
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{% block title %}{{ site.title }}{% endblock %}</title>
</head>
<body>
<header>
<h1 class="masthead"><a href="/">{{ site.title|upper }}</a></h1>
<p class="tagline">{{ site.tagline|default("") }}</p>
<nav>{% for p in pages %}{% if not loop.first %} &middot; {% endif %}{{ chip(p.title, p.url, cls="section") }}{% endfor %} &middot; {{ chip("All topics", "/tags/") }}</nav>
</header>
{% block content %}{% endblock %}
{% include "rail.html" %}
<footer><p>{{ site.author }} &middot; {{ site.sections|join(" / ") }} &middot; <a href="{{ site.base_url }}/feed.xml">feed</a> &middot; <a href="{{ site.base_url }}/sitemap.xml">sitemap</a></p></footer>
</body>
</html>
""",
    'rail.html': """\
<aside class="rail">
<p class="featured">Featured:{% for t in tags %}{% if t.post_count >= site.featured_min %} {{ chip(t.name, t.url) }}{% endif %}{% endfor %}</p>
</aside>
""",
    'index.html': """\
{% extends "layout.html" %}
{% block title %}{{ site.title }}{% if pagination.number > 1 %} &middot; page {{ pagination.number }}{% endif %}{% endblock %}
{% block content %}
<section class="cards">
{%- for post in posts %}
{{ card(post) }}
{%- endfor %}
</section>
<nav class="pager">
{%- if pagination.has_prev %}{{ chip("&laquo; newer", pagination.prev_url) }}{% endif %}
{%- for l in pagination.links %}
{%- set d = l.number - pagination.number %}
{%- if l.current %} <b>{{ l.number }}</b>
{%- elif (d >= -3 and d <= 3) or l.number % 50 == 0 or loop.first or loop.last %} {{ chip(l.number, l.url) }}
{%- endif %}
{%- endfor %}
{%- if pagination.has_next %} {{ chip("older &raquo;", pagination.next_url) }}{% endif %}
</nav>
{% endblock %}
""",
    'post.html': """\
{% extends "layout.html" %}
{% block title %}{{ post.title }} &middot; {{ site.title }}{% endblock %}
{% block content %}
<article>
<h2>{{ post.title }}</h2>
<p class="byline">{{ post.date_long }} &middot; {{ post.tags|length }} topic{% if post.tags|length != 1 %}s{% endif %}: {% for t in post.tags %}{{ chip(t.name, t.url) }} <small>{{ t.post_count }}</small>{% if not loop.last %}, {% endif %}{% endfor %}</p>
{{ post.content }}</article>
<nav class="adjacent">{% if post.newer %}{{ chip("&larr; " ~ post.newer.title, post.newer.url, cls="newer") }} <small>{{ post.newer.date_long }}</small>{% endif %}{% if post.older %} {{ chip(post.older.title ~ " &rarr;", post.older.url, cls="older") }} <small>{{ post.older.date_long }}</small>{% endif %}</nav>
{% endblock %}
""",
    'page.html': """\
{% extends "layout.html" %}
{% block title %}{{ page.title }}{% endblock %}
{% block content %}
<article class="page">{{ page.content }}</article>
{% endblock %}
""",
    'tag.html': """\
{% extends "layout.html" %}
{% block title %}{{ tag.name }} &middot; {{ super() }}{% endblock %}
{% block content %}
{% set newest = posts|first %}{% set oldest = posts|last %}
<h2>{{ tag.name }}</h2>
<p>{{ tag.post_count }} stories from {{ oldest.date_long }} to {{ newest.date_long }}.</p>
<ol class="stories">
{%- for post in posts %}
<li>{{ chip(post.title, post.url) }} <small>{{ post.date|replace("-", ".") }}{% if post.tags|length > 1 %} &middot; {{ post.tags|length - 1 }} more topic{% if post.tags|length > 2 %}s{% endif %}{% endif %}</small></li>
{%- endfor %}
</ol>
{% endblock %}
""",
    'tags.html': """\
{% extends "layout.html" %}
{% block title %}Topics &middot; {{ super() }}{% endblock %}
{% block content %}
<h2>All topics</h2>
{%- for letter in "abcdefghijklmnopqrstuvwxyz" %}
<h3 id="{{ letter }}">{{ letter|upper }}</h3>
<p>{% for t in tags %}{% if t.slug[0] == letter %}{{ chip(t.name, t.url) }} ({{ t.post_count }}) {% endif %}{% endfor %}</p>
{%- endfor %}
{% endblock %}
""",
}


# ---------------------------------------------------------------------------
# Sites
# ---------------------------------------------------------------------------

TECH_TAGS = ['Rust', 'Go', 'C++ Internals', 'Python', 'D Language', 'Compilers', 'Databases',
             'Distributed Systems', 'Networking', 'Operating Systems', 'Performance', 'Testing',
             'Security', 'Cryptography', 'Web Development', 'Frontend', 'CSS', 'JavaScript',
             'TypeScript', 'WebAssembly', 'Graphics', 'Game Development', 'Audio', 'Machine Learning',
             'Statistics', 'Data Engineering', 'DevOps', 'Kubernetes', 'Cloud', 'Linux', 'macOS',
             'Embedded', 'Hardware', 'Retrocomputing', 'Algorithms', 'Data Structures',
             'Type Systems', 'Functional Programming', 'Concurrency', 'Async I/O', 'Parsing',
             'Text Editors', 'Tooling', 'Build Systems', 'Version Control', 'Open Source',
             'Career', 'Writing', 'Book Reviews', 'Conference Notes', 'Interviews', 'History',
             'Math', 'Physics', 'Typography', 'Accessibility', 'UX', 'Mobile', 'Release Notes',
             'Meta']


def blog_archive():
    """001: a large, ordinary technical blog with a production-style theme."""
    rng = random.Random(1001)
    s = gt.SiteSpec('blog_archive_1200_posts')
    s.config([('title', 'Notes from the Machine Room'), ('base_url', 'https://machineroom.example'),
              ('author', 'J. Q. Engineer'), ('posts_per_page', 10),
              ('description', 'Long-running engineering blog: systems, languages, tools.'),
              ('since', 2006), ('year', 2026), ('popular_threshold', 300), ('pager_window', 3),
              ('keywords', ['systems', 'compilers', 'Performance', 'tooling', 'Rust', 'writing'])])
    used = set()
    start = datetime.date(2006, 1, 2)
    n = 1200
    for k in range(n):
        t = title(rng)
        slug = gt.unique_slug(ref.slugify(t), used)
        date = (start + datetime.timedelta(days=k * 7400 // n + rng.randint(0, 2))).isoformat()
        tags = zipf_pick(rng, TECH_TAGS, rng.choice([1, 2, 2, 3, 3, 4]))
        fm = [('title', t), ('date', date), ('tags', tags)]
        if rng.random() < 0.5:
            fm.append(('slug', slug))
            fname = '%04d-%s.md' % (k, slug[:20])
        else:
            fname = slug + '.md'
        if rng.random() < 0.03:
            fm.append(('draft', True))
        s.post(fname, fm, body(rng, rng.randint(600, 2600), 0.06))
    for name in ['about', 'archive-policy', 'colophon', 'contact', 'now', 'projects', 'talks',
                 'uses']:
        s.page(name + '.md', [('title', name.replace('-', ' ').title())],
               '# %s\n\n' % name.replace('-', ' ').title() + body(rng, 3000, 0.06))
    s.templates(THEME_PORTAL)
    static_tree(s, rng, 60)
    return s


ESSAY_TOPICS = ['Union', 'Taxation', 'Judiciary', 'Senate', 'Executive', 'Militia', 'Commerce',
                'Powers', 'Liberty', 'Virtue', 'Fortune', 'Friendship', 'Nature', 'Studies',
                'Ambition', 'Fables', 'Morals', 'History', 'Rhetoric', 'Law']


def long_reads():
    """002: long, structurally and inline-dense essays (Markdown-bound)."""
    rng = random.Random(2002)
    s = gt.SiteSpec('long_reads_markdown_heavy')
    s.config([('title', 'The Long Read'), ('base_url', 'https://longread.example/archive'),
              ('author', 'Publius & Friends'), ('posts_per_page', 5)])
    used = set()
    start = datetime.date(1990, 3, 1)
    for k in range(230):
        t = title(rng, 3, 9)
        slug = gt.unique_slug(ref.slugify(t), used)
        date = (start + datetime.timedelta(days=k * 61)).isoformat()
        tags = zipf_pick(rng, ESSAY_TOPICS, rng.randint(1, 3), 0.8)
        dense = rng.random() < 0.75
        b = body(rng, rng.randint(16000, 40000), 0.45 if dense else 0.15, dense=dense,
                 structure=1.3)
        s.post('%03d.md' % k, [('title', t), ('date', date), ('slug', slug), ('tags', tags)], b)
    s.page('about.md', [('title', 'About')], '# About\n\n' + body(rng, 6000, 0.2, True))
    s.templates(gt.THEME_ARCHIVE)
    s.text('static/robots.txt', gt.ROBOTS)
    return s


MAG_SECTIONS = ['World', 'Politics', 'Business', 'Science', 'Technology', 'Culture', 'Books',
                'Travel', 'Food', 'Sport', 'Opinion', 'Health', 'Climate', 'Education', 'Arts',
                'Music', 'Film', 'Design', 'Media', 'Law']


def magazine():
    """003: a news magazine with many short stories and a template-heavy theme."""
    rng = random.Random(3003)
    s = gt.SiteSpec('magazine_template_heavy')
    places = rng.sample(sorted({w.capitalize() for w in WORDS if 5 <= len(w) <= 9}), 400)
    tag_names = MAG_SECTIONS + ['%s %s' % (rng.choice(places), rng.choice(['Report', 'Diary',
                                'Dispatch', 'Letter', 'Review', 'Notes', 'Watch']))
                                for _ in range(200)]
    seen, uniq = set(), []
    for t in tag_names:
        if ref.slugify(t) not in seen:
            seen.add(ref.slugify(t))
            uniq.append(t)
    tag_names = uniq[:180]
    s.config([('title', 'The Weekly Ledger'), ('base_url', 'https://ledger.example'),
              ('author', 'The Editors'), ('posts_per_page', 3),
              ('tagline', 'All the news that fits, and some that does not.'),
              ('featured_min', 150), ('sections', MAG_SECTIONS[:8])])
    used = set()
    start = datetime.date(2015, 1, 1)
    n = 1800
    for k in range(n):
        t = title(rng, 3, 8)
        slug = gt.unique_slug(ref.slugify(t), used)
        date = (start + datetime.timedelta(days=k * 4000 // n)).isoformat()
        tags = [rng.choice(MAG_SECTIONS)] + zipf_pick(rng, tag_names[20:], rng.randint(1, 4), 0.9)
        s.post('%04d-%s.md' % (k, slug[:24]),
               [('title', t), ('date', date), ('slug', slug), ('tags', tags)],
               body(rng, rng.randint(300, 1000), 0.07, structure=0.6, lead=(1, 2)))
    for name in MAG_SECTIONS[:8]:
        s.page(name.lower() + '.md', [('title', name)], '# %s\n\n' % name + body(rng, 1500, 0.06))
    s.templates(THEME_MAGAZINE)
    s.text('static/robots.txt', gt.ROBOTS)
    return s


CASES = [blog_archive, long_reads, magazine]


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def build(number, spec, oracles):
    case = os.path.join(HERE, '%03d_%s' % (number, spec.name))
    input_dir = os.path.join(case, 'input')
    expected_dir = os.path.join(case, 'expected')
    shutil.rmtree(case, ignore_errors=True)
    os.makedirs(input_dir)
    gt.write_site(spec, input_dir)

    renders = []

    def hook(template, context, rel_path, output):
        if oracles:
            renders.append({'template': template, 'context': context,
                            'path': rel_path, 'output': output})

    ref.generate(input_dir, expected_dir, hook)

    for kind in ('posts', 'pages'):
        directory = os.path.join(input_dir, 'content', kind)
        for filename in ref.list_markdown(directory):
            raw = ref.read_text(os.path.join(directory, filename))
            _, b = ref.split_front_matter(raw, filename)
            gt.check_markdown_guarantees('%s/%s/%s' % (spec.name, kind, filename), b)
    gt.check_site_guarantees(spec.name, input_dir)
    gt.check_xml(spec.name, os.path.join(expected_dir, 'feed.xml'))
    gt.check_xml(spec.name, os.path.join(expected_dir, 'sitemap.xml'))
    if oracles:
        gt.check_content_oracles(spec.name, input_dir)
        gt.check_jinja_oracle(spec.name, gt.raw_templates(input_dir), renders)

    def tree(root):
        files = [os.path.join(dp, n) for dp, _, names in os.walk(root) for n in names]
        return len(files), sum(os.path.getsize(f) for f in files)

    fi, si = tree(input_dir)
    fo, so = tree(expected_dir)
    print('%-36s input %5d files %8.1f KB   expected %5d files %8.1f KB'
          % (os.path.basename(case), fi, si / 1024, fo, so / 1024))


def main():
    sys.setrecursionlimit(20000)
    oracles = '--no-oracles' not in sys.argv[1:]
    if oracles and not (os.path.exists(gt.CMARK) and os.path.exists(gt.VENV_PYTHON)):
        print('cmark or the Jinja2 oracle venv is missing; rerun with --no-oracles')
        return 2
    for name in os.listdir(HERE):
        if re.match(r'^\d{3}_', name):
            shutil.rmtree(os.path.join(HERE, name))
    for number, make in enumerate(CASES, 1):
        build(number, make(), oracles)
    if gt.failures:
        print('\n%d check failure(s); bench/ is not trustworthy' % len(gt.failures))
        return 1
    print('\n%d benchmark sites generated%s' % (len(CASES), ' and cross-checked' if oracles else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
