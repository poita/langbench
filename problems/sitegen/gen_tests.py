#!/usr/bin/env python3
"""Generates tests/NNN_name/{input,expected} for the `sitegen` problem.

Every site is either built from embedded literals or derived deterministically
from a vendored public-domain text in corpus/, so re-running this script
reproduces the suite exactly. The expected output tree of each site is
produced by reference/main.py and cross-checked against three external
oracles, any disagreement aborting the run:

  * `tomllib` (Python standard library) re-parses every TOML-subset document
    (site.toml and every front matter block) and must agree with the
    reference's own parser;
  * `cmark` 0.31.2 re-converts every Markdown body and every excerpt source
    and must agree with the reference's Markdown output;
  * Jinja2 3.1 (in ../../.oracle-venv), with StrictUndefined, autoescape off
    and no block trimming, re-renders every generated page from the same
    template sources and the same context and must produce the same bytes.

feed.xml and sitemap.xml are additionally parsed with xml.etree to confirm
they are well-formed XML, and every Markdown body is checked against the
subset guarantees restated in SPEC.md.

    python3 gen_tests.py
"""
import datetime
import html.entities
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
CORPUS = os.path.join(HERE, 'corpus')
VENV_PYTHON = os.path.normpath(os.path.join(HERE, '..', '..', '.oracle-venv', 'bin', 'python'))
CMARK = os.environ.get('CMARK', shutil.which('cmark') or '/opt/homebrew/bin/cmark')

sys.path.insert(0, os.path.join(HERE, 'reference'))
import main as ref  # noqa: E402


# ---------------------------------------------------------------------------
# TOML-subset writing
# ---------------------------------------------------------------------------

def toml_string(s):
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == '\\':
            out.append('\\\\')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\t':
            out.append('\\t')
        elif ch == '\r':
            out.append('\\r')
        elif ord(ch) < 0x20:
            out.append('\\u%04X' % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


def toml_value(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return toml_string(v)
    if isinstance(v, list):
        return '[' + ', '.join(toml_string(x) for x in v) + ']'
    raise TypeError(v)


def toml_document(items):
    return ''.join('%s = %s\n' % (k, toml_value(v)) for k, v in items)


def content_file(front_matter, body):
    """Builds a `+++` front matter document; `body` is used verbatim."""
    return '+++\n' + toml_document(front_matter) + '+++\n' + body


# ---------------------------------------------------------------------------
# Site description
# ---------------------------------------------------------------------------

class SiteSpec:
    """The files of one test site, keyed by path relative to the input root."""

    def __init__(self, name):
        self.name = name
        self.files = {}

    def text(self, path, content):
        self.files[path] = content.encode('utf-8')
        return self

    def binary(self, path, data):
        self.files[path] = data
        return self

    def config(self, items):
        return self.text('site.toml', toml_document(items))

    def post(self, filename, front_matter, body):
        return self.text('content/posts/' + filename, content_file(front_matter, body))

    def page(self, filename, front_matter, body):
        return self.text('content/pages/' + filename, content_file(front_matter, body))

    def templates(self, theme):
        for name, source in theme.items():
            self.text('templates/' + name, source)
        return self


CASES = []


def add(spec):
    CASES.append(spec)
    return spec


# ---------------------------------------------------------------------------
# Themes
# ---------------------------------------------------------------------------

# A bare theme with no inheritance, so the generated pages are easy to read.
THEME_MIN = {
    'index.html': """\
INDEX {{ pagination.number }}/{{ pagination.total_pages }} total={{ pagination.total_posts }}
{% for post in posts %}- {{ post.slug }} | {{ post.date }} | {{ post.title }} | {{ post.url }} | older={% if post.older %}{{ post.older.slug }}{% else %}-{% endif %} newer={% if post.newer %}{{ post.newer.slug }}{% else %}-{% endif %}
{% else %}(no posts)
{% endfor %}prev={% if pagination.has_prev %}{{ pagination.prev_url }}{% else %}-{% endif %} next={% if pagination.has_next %}{{ pagination.next_url }}{% else %}-{% endif %}
links:{% for l in pagination.links %} {{ l.number }}{% if l.current %}*{% endif %}{% endfor %}
nav:{% for p in pages %} {{ p.slug }}={{ p.title }}{% endfor %}
tags:{% for t in tags %} {{ t.slug }}({{ t.post_count }}){% endfor %}
""",
    'post.html': """\
POST {{ post.slug }} {{ post.date }} {{ post.date_long }}
title: {{ post.title }}
url: {{ post.url }}
permalink: {{ post.permalink }}
tags:{% for t in post.tags %} {{ t.name }}->{{ t.url }}({{ t.post_count }}){% endfor %}
older: {% if post.older %}{{ post.older.slug }} {{ post.older.date }} {{ post.older.title }}{% else %}-{% endif %}
newer: {% if post.newer %}{{ post.newer.slug }} {{ post.newer.date }} {{ post.newer.title }}{% else %}-{% endif %}
--- content ---
{{ post.content }}--- excerpt ---
{{ post.excerpt }}--- end ---
""",
    'page.html': """\
PAGE {{ page.slug }}
title: {{ page.title }}
url: {{ page.url }}
permalink: {{ page.permalink }}
--- content ---
{{ page.content }}--- end ---
""",
    'tag.html': """\
TAG {{ tag.name }} slug={{ tag.slug }} url={{ tag.url }} count={{ tag.post_count }}
{% for post in posts %}- {{ post.date }} {{ post.slug }} {{ post.title }} older={% if post.older %}{{ post.older.slug }}{% else %}-{% endif %} newer={% if post.newer %}{{ post.newer.slug }}{% else %}-{% endif %}
{% endfor %}same={% if posts|length == tag.posts|length %}yes{% else %}no{% endif %}
""",
    'tags.html': """\
TAGS {{ tags|length }}
{% for t in tags %}{{ t.slug }} | {{ t.name }} | {{ t.url }} | {{ t.post_count }}
{% endfor %}site: {{ site.title }} <{{ site.base_url }}> by {{ site.author }}, {{ site.posts_per_page }}/page
""",
}

# THEME_MIN with a tags.html that also renders every `site.toml` value, so that
# the exact result of parsing each TOML form (escapes, integers, booleans,
# arrays) and the file order of the keys are visible in the expected output.
THEME_TOML = dict(THEME_MIN, **{
    'tags.html': """\
TAGS {{ tags|length }}
{% for t in tags %}{{ t.slug }} | {{ t.name }} | {{ t.url }} | {{ t.post_count }}
{% endfor %}site: {{ site.title }} <{{ site.base_url }}> by {{ site.author }}, {{ site.posts_per_page }}/page
keys:{% for k in site %} {{ k }}{% endfor %}
tagline=[{{ site.tagline }}]
year={{ site.year }} plus one={{ site.year + 1 }}
zero={{ site.zero }}
enabled={{ site.enabled }} truthy={% if site.enabled %}yes{% else %}no{% endif %}
keywords=[{{ site.keywords|join("|") }}] n={{ site.keywords|length }}
empty_list n={{ site.empty_list|length }} truthy={% if site.empty_list %}yes{% else %}no{% endif %}
hash_inside=[{{ site.hash_inside }}]
unicode_escape=[{{ site.unicode_escape }}]
carriage length={{ site.carriage|length }}
""",
})


# A realistic blog theme: a base layout with an included nav, block overrides,
# pagination controls and adjacent-post navigation.
THEME_BLOG = {
    'base.html': """\
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{% block title %}{{ site.title }}{% endblock %}</title>
<link rel="alternate" type="application/atom+xml" href="{{ site.base_url }}/feed.xml">
<link rel="stylesheet" href="/css/site.css">
</head>
<body>
<header class="site">
<a class="brand" href="/">{{ site.title }}</a>
{% include "nav.html" %}
</header>
<main>
{% block main %}{% endblock %}
</main>
<footer class="site"><p>&copy; {{ site.author }}</p></footer>
</body>
</html>
""",
    'nav.html': """\
<nav>
<ul>
{%- for p in pages %}
<li><a href="{{ p.url }}">{{ p.title }}</a></li>
{%- endfor %}
<li><a href="/tags/">Tags</a></li>
</ul>
</nav>

""",
    'index.html': """\
{% extends "base.html" %}
{% block title %}{% if pagination.number > 1 %}Page {{ pagination.number }} &middot; {% endif %}{{ site.title }}{% endblock %}
{% block main %}
{% for post in posts %}
<article class="summary">
<h2><a href="{{ post.url }}">{{ post.title }}</a></h2>
<p class="meta"><time datetime="{{ post.date }}">{{ post.date_long }}</time>{% for t in post.tags %} <a class="tag" href="{{ t.url }}">{{ t.name }}</a>{% endfor %}</p>
{{ post.excerpt }}</article>
{% else %}
<p class="empty">Nothing has been written yet.</p>
{% endfor %}
<nav class="pager">
{%- if pagination.has_prev %} <a rel="prev" href="{{ pagination.prev_url }}">Newer</a>{% endif %}
{%- for l in pagination.links %} {% if l.current %}<strong>{{ l.number }}</strong>{% else %}<a href="{{ l.url }}">{{ l.number }}</a>{% endif %}{% endfor %}
{%- if pagination.has_next %} <a rel="next" href="{{ pagination.next_url }}">Older</a>{% endif %}
</nav>
<p class="count">{{ pagination.total_posts }} posts in total.</p>
{% endblock %}
""",
    'post.html': """\
{% extends "base.html" %}
{% block title %}{{ post.title }} &middot; {{ site.title }}{% endblock %}
{% block main %}
<article class="post">
<h1>{{ post.title }}</h1>
<p class="meta">By {{ site.author }} on <time datetime="{{ post.date }}">{{ post.date_long }}</time></p>
{{ post.content }}{% if post.tags %}<p class="tags">Tagged{% for t in post.tags %} <a href="{{ t.url }}">{{ t.name }}</a>{% endfor %}</p>
{% endif %}</article>
<nav class="adjacent">
{%- if post.newer %}
<a class="newer" rel="next" href="{{ post.newer.url }}">&larr; {{ post.newer.title }}</a>
{%- endif %}
{%- if post.older %}
<a class="older" rel="prev" href="{{ post.older.url }}">{{ post.older.title }} &rarr;</a>
{%- endif %}
</nav>
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
{% block main %}
<h1>Posts tagged &ldquo;{{ tag.name }}&rdquo;</h1>
<p>{{ tag.post_count }} post{% if tag.post_count != 1 %}s{% endif %}.</p>
<ul class="postlist">
{%- for post in posts %}
<li><time datetime="{{ post.date }}">{{ post.date }}</time> <a href="{{ post.url }}">{{ post.title }}</a></li>
{%- endfor %}
</ul>
{% endblock %}
""",
    'tags.html': """\
{% extends "base.html" %}
{% block title %}Tags &middot; {{ site.title }}{% endblock %}
{% block main %}
<h1>Tags</h1>
{% if tags %}
<ul class="tagcloud">
{%- for t in tags %}
<li><a href="{{ t.url }}">{{ t.name }}</a> <span class="count">{{ t.post_count }}</span></li>
{%- endfor %}
</ul>
{% else %}
<p>No tags yet.</p>
{% endif %}
{% endblock %}
""",
}

# A second realistic theme, leaning on macros, `set` and filters.
THEME_ESSAY = {
    'base.html': """\
{% macro chip(label, href) %}<a class="chip" href="{{ href }}">{{ label }}</a>{% endmacro -%}
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>{% block head %}{{ site.title }}{% endblock %}</title>
</head>
<body class="{% block bodyclass %}plain{% endblock %}">
<h1 class="site"><a href="/">{{ site.title|upper }}</a></h1>
<p class="sub">{{ site.subtitle|default("") }}</p>
<p class="keywords">{{ site.keywords|sort|join(" &middot; ") }}</p>
{% include "menu.html" %}
<hr>
{% block content %}{% endblock %}
<hr>
<p class="foot">{{ site.author }} &middot; est. {{ site.since|int }} &middot; <a href="{{ site.base_url }}/feed.xml">feed</a></p>
</body>
</html>
""",
    'menu.html': """\
<nav>{% for p in pages %}{% if not loop.first %} | {% endif %}<a href="{{ p.url }}">{{ p.title }}</a>{% endfor %}{% if pages %} | {% endif %}<a href="/tags/">tags</a></nav>

""",
    'index.html': """\
{% extends "base.html" %}
{% block head %}{{ site.title }} &mdash; page {{ pagination.number }} of {{ pagination.total_pages }}{% endblock %}
{% block bodyclass %}index{% endblock %}
{% block content %}
{% set shown = posts|length %}
<p>Showing {{ shown }} of {{ pagination.total_posts }} essays.</p>
<ol class="essays">
{%- for post in posts %}
<li>
<a href="{{ post.url }}">{{ post.title }}</a>
<small>{{ post.date_long }}</small>
{%- if post.tags %} <em>{% for t in post.tags %}{{ t.name }}{% if not loop.last %}, {% endif %}{% endfor %}</em>{% endif %}
{{ post.excerpt }}</li>
{%- endfor %}
</ol>
<p class="pager">
{%- if pagination.has_prev %}<a href="{{ pagination.prev_url }}">&laquo; newer</a>{% endif %}
{%- if pagination.has_prev %}{% if pagination.has_next %} | {% endif %}{% endif %}
{%- if pagination.has_next %}<a href="{{ pagination.next_url }}">older &raquo;</a>{% endif %}
</p>
{% endblock %}
""",
    'post.html': """\
{% extends "base.html" %}
{% block head %}{{ post.title }} ({{ site.title }}){% endblock %}
{% block bodyclass %}essay{% endblock %}
{% block content %}
<article>
<h2>{{ post.title }}</h2>
<p class="meta">{{ post.date|replace("-", "/") }} &middot; {{ post.tags|length }} tags &middot; slug {{ post.slug|upper }}</p>
{{ post.content }}</article>
<p class="chips">{% for t in post.tags %}{{ chip(t.name, t.url) }} {% endfor %}</p>
<p class="nav">{% if post.newer %}<a href="{{ post.newer.url }}">{{ post.newer.title }}</a>{% else %}(newest){% endif %} / {% if post.older %}<a href="{{ post.older.url }}">{{ post.older.title }}</a>{% else %}(oldest){% endif %}</p>
{% endblock %}
""",
    'page.html': """\
{% extends "base.html" %}
{% block head %}{{ page.title }}{% endblock %}
{% block bodyclass %}static{% endblock %}
{% block content %}
{{ page.content }}<p><a href="{{ page.permalink }}">{{ page.permalink }}</a></p>
{% endblock %}
""",
    'tag.html': """\
{% extends "base.html" %}
{% block head %}{{ tag.name|lower }} ({{ tag.post_count }}){% endblock %}
{% block bodyclass %}tag{% endblock %}
{% block content %}
{% set newest = tag.posts|first %}
<h2>{{ tag.name }}</h2>
<p>{{ tag.post_count }} essays; newest is <a href="{{ newest.url }}">{{ newest.title }}</a> ({{ newest.date_long }}).</p>
<ul>
{%- for post in posts %}
<li>{{ chip(post.date, post.url) }} {{ post.title|escape }}</li>
{%- endfor %}
</ul>
{% endblock %}
""",
    'tags.html': """\
{% extends "base.html" %}
{% block head %}all tags{% endblock %}
{% block bodyclass %}tags{% endblock %}
{% block content %}
<dl>
{%- for t in tags %}
<dt><a href="{{ t.url }}">{{ t.name }}</a></dt><dd>{{ t.post_count }}</dd>
{%- endfor %}
</dl>
<p>{{ tags|length }} tags, {{ pages|length }} pages.</p>
{% endblock %}
""",
}

# A third theme: three-level inheritance, `super()`, includes that read
# variables set by the including template, and a macro shared through the
# layout.
THEME_ARCHIVE = {
    'layout.html': """\
{% macro authorlist(items) %}{% for t in items %}{% if not loop.first %}, {% endif %}<a href="{{ t.url }}">{{ t.name }}</a>{% endfor %}{% endmacro -%}
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{% block title %}{{ site.title }}{% endblock %}</title>
</head>
<body>
{% include "header.html" %}
<main>
{% block main %}{% endblock %}
</main>
{% include "footer.html" %}
</body>
</html>
""",
    'header.html': """\
<header>
<p class="kicker">{{ site.title }} &mdash; {{ site.author }}</p>
<nav>{% for p in pages %}<a href="{{ p.url }}">{{ p.title }}</a> {% endfor %}<a href="/tags/">Authors</a></nav>
</header>

""",
    'footer.html': """\
<footer>
<p><a href="{{ site.base_url }}/feed.xml">Atom feed</a> &middot; <a href="{{ site.base_url }}/sitemap.xml">Sitemap</a></p>
</footer>
""",
    'article.html': """\
{% extends "layout.html" %}
{% block main %}
<article class="paper">
{% block article %}{% endblock %}
</article>
{% endblock %}
""",
    'index.html': """\
{% extends "layout.html" %}
{% block title %}{{ super() }}{% if pagination.number > 1 %} (page {{ pagination.number }}){% endif %}{% endblock %}
{% block main %}
<table class="papers">
<tr><th>#</th><th>Paper</th><th>Published</th></tr>
{%- for post in posts %}
<tr><td>{{ (pagination.number - 1) * site.posts_per_page + loop.index }}</td><td><a href="{{ post.url }}">{{ post.title }}</a></td><td>{{ post.date }}</td></tr>
{%- endfor %}
</table>
<p class="pager">
{%- for l in pagination.links %}{% if l.current %}[{{ l.number }}]{% else %}<a href="{{ l.url }}">{{ l.number }}</a>{% endif %} {% endfor %}
</p>
{% endblock %}
""",
    'post.html': """\
{% extends "article.html" %}
{% block title %}{{ post.title }} &middot; {{ super() }}{% endblock %}
{% block article %}
<h1>{{ post.title }}</h1>
<p class="byline">{{ post.date_long }} &middot; {{ authorlist(post.tags) }}</p>
{{ post.content }}<p class="seq">
{%- if post.newer %}<a href="{{ post.newer.url }}">previous in order</a>{% endif %}
{%- if post.older %} <a href="{{ post.older.url }}">next in order</a>{% endif %}
</p>
{%- endblock %}
""",
    'page.html': """\
{% extends "article.html" %}
{% block title %}{{ page.title }}{% endblock %}
{% block article %}
{{ page.content }}
{%- endblock %}
""",
    'tag.html': """\
{% extends "layout.html" %}
{% block title %}{{ tag.name }} &middot; {{ super() }}{% endblock %}
{% block main %}
<h1>{{ tag.name }}</h1>
<p>{{ tag.post_count }} papers.</p>
<ol>
{%- for post in posts %}
<li><a href="{{ post.url }}">{{ post.title }}</a> <time>{{ post.date }}</time></li>
{%- endfor %}
</ol>
{% endblock %}
""",
    'tags.html': """\
{% extends "layout.html" %}
{% block title %}Authors &middot; {{ super() }}{% endblock %}
{% block main %}
<h1>Authors</h1>
<ul>
{%- for t in tags %}
<li><a href="{{ t.url }}">{{ t.name }}</a> ({{ t.post_count }})</li>
{%- endfor %}
</ul>
{% endblock %}
""",
}

SITE_CSS = """\
:root { --ink: #1b1b1b; --paper: #fbfaf7; }
body { margin: 0 auto; max-width: 42rem; color: var(--ink); background: var(--paper); }
a.tag, a.chip { font-size: 0.85em; }
"""

ROBOTS = "User-agent: *\nAllow: /\n"

# A 1x1 transparent PNG, used to check that binary static files are copied
# byte for byte.
PNG_1X1 = bytes.fromhex(
    '89504e470d0a1a0a0000000d494844520000000100000001080600000'
    '01f15c4890000000a49444154789c6360000002000100' 'ffff030000060005' '57bfabd4'
    '0000000049454e44ae426082')


# ---------------------------------------------------------------------------
# Hand-written sites
# ---------------------------------------------------------------------------

BASE_CONFIG = [('title', 'Test Site'), ('base_url', 'https://example.com'),
               ('author', 'A. Author'), ('posts_per_page', 3)]


def minimal():
    s = SiteSpec('minimal')
    s.config([('title', 'One Post'), ('base_url', 'https://one.example'),
              ('author', 'Solo'), ('posts_per_page', 5)])
    s.post('only.md', [('title', 'The only post'), ('date', '2021-06-01')],
           'Just one paragraph.\n')
    s.templates(THEME_MIN)
    return s


def no_posts():
    s = SiteSpec('no_posts')
    s.config([('title', 'Empty'), ('base_url', 'https://empty.example'),
              ('author', 'Nobody'), ('posts_per_page', 4)])
    s.page('about.md', [('title', 'About this empty place')],
           'There is nothing here yet.\n')
    s.templates(THEME_MIN)
    return s


def drafts():
    s = SiteSpec('drafts')
    s.config(BASE_CONFIG)
    s.post('published.md',
           [('title', 'Published'), ('date', '2022-01-02'), ('tags', ['Kept'])],
           'This one is visible.\n')
    s.post('hidden.md',
           [('title', 'Hidden'), ('date', '2022-03-04'), ('tags', ['Gone', 'Kept']),
            ('draft', True)],
           'This one must not appear anywhere.\n')
    s.post('also-hidden.md',
           [('title', 'Also hidden'), ('date', '2022-05-06'), ('draft', True)],
           'Nor this one.\n')
    s.page('shown.md', [('title', 'Shown page')], 'Visible page.\n')
    s.page('secret.md', [('title', 'Secret page'), ('draft', True)], 'Invisible page.\n')
    s.templates(THEME_MIN)
    return s


def single_tag():
    s = SiteSpec('single_tag')
    s.config(BASE_CONFIG)
    s.post('a.md', [('title', 'A'), ('date', '2020-01-01'), ('tags', ['Lonely'])],
           'Only post with this tag.\n')
    s.post('b.md', [('title', 'B'), ('date', '2020-01-02'), ('tags', ['Shared'])],
           'Second.\n')
    s.post('c.md', [('title', 'C'), ('date', '2020-01-03'), ('tags', ['Shared'])],
           'Third.\n')
    s.templates(THEME_MIN)
    return s


def page_tag_same_slug():
    s = SiteSpec('page_tag_same_slug')
    s.config(BASE_CONFIG)
    s.post('first.md', [('title', 'First'), ('date', '2023-04-05'),
                        ('tags', ['Notes', 'notes-2'])],
           'A post tagged `Notes`.\n')
    s.page('notes.md', [('title', 'Notes')],
           'A page whose slug is also a tag slug, but at a different path.\n')
    s.page('tags-overview.md', [('title', 'Tags overview'), ('slug', 'tag')],
           'Another near-miss slug.\n')
    s.templates(THEME_MIN)
    return s


def pagination_exact():
    s = SiteSpec('pagination_exact')
    s.config([('title', 'Exact'), ('base_url', 'https://exact.example'),
              ('author', 'P. Ager'), ('posts_per_page', 2)])
    for i in range(6):
        s.post('p%d.md' % i,
               [('title', 'Post %d' % i), ('date', '2020-02-%02d' % (i + 1))],
               'Body of post %d.\n' % i)
    s.templates(THEME_MIN)
    return s


def pagination_remainder():
    s = SiteSpec('pagination_remainder')
    s.config([('title', 'Remainder'), ('base_url', 'https://rem.example'),
              ('author', 'P. Ager'), ('posts_per_page', 3)])
    for i in range(7):
        s.post('p%d.md' % i,
               [('title', 'Post %d' % i), ('date', '2020-02-%02d' % (i + 1))],
               'Body of post %d.\n' % i)
    s.templates(THEME_MIN)
    return s


def date_ties():
    s = SiteSpec('date_ties')
    s.config(BASE_CONFIG)
    for slug, title in [('zebra', 'Zebra'), ('apple', 'Apple'), ('mango', 'Mango')]:
        s.post(slug + '.md', [('title', title), ('date', '2019-09-09')],
               'Same date as the others.\n')
    s.post('aaa-first-by-name.md',
           [('title', 'Last by slug'), ('date', '2019-09-09'), ('slug', 'zzz-last')],
           'Same date again; the file name sorts first but the slug sorts last.\n')
    s.post('later.md', [('title', 'Later'), ('date', '2019-09-10')], 'Newest.\n')
    s.post('earlier.md', [('title', 'Earlier'), ('date', '2019-09-08')], 'Oldest.\n')
    s.templates(THEME_MIN)
    return s


def slug_override():
    s = SiteSpec('slug_override')
    s.config(BASE_CONFIG)
    s.post('2021-07-04-independence.md',
           [('title', 'Independence'), ('date', '2021-07-04'), ('slug', 'independence')],
           'The file name and the slug differ.\n')
    s.post('untitled-2.md', [('title', 'Untitled two'), ('date', '2021-07-05')],
           'The slug comes from the file name.\n')
    s.page('contact-us-now.md', [('title', 'Contact'), ('slug', 'contact')],
           'Mail to nobody.\n')
    s.templates(THEME_MIN)
    return s


def toml_edge():
    s = SiteSpec('toml_edge')
    s.text('site.toml', """\
# The site configuration.

title = "The \\"Quoted\\" Site"      # a trailing comment
base_url   =    "https://toml.example"
author="A\\tB"
posts_per_page = 2

   # an indented comment
tagline = "first\\nsecond"
year = -44
enabled = false
keywords = ["gamma", "alpha", "beta",]
empty_list = []
hash_inside = "not # a comment"
unicode_escape = "\\u00e9t\\u00e9"
carriage = "a\\rb"
zero = 0
""")
    s.text('content/posts/one.md', """\
+++
title = "Edge cases \\u2014 caf\\u00e9"
date   =   "2020-12-31"
tags = [ "Alpha" ,  "Beta" , ]
slug = "edge"
draft = false

# a comment inside the front matter
note = "a \\\\ backslash and a \\"quote\\""
+++
Body after the front matter.

The `title` above contains quotes.
""")
    s.text('content/posts/two.md', """\
+++
title = "Minimal front matter"
date = "2020-12-30"
+++
Only the two required keys.
""")
    s.text('content/posts/delimiters.md', """\
+++
title = "Delimiters +++ in a value"
date = "2020-12-29"
+++
The front matter ends at the first line that is exactly three plus signs.

+++

++++

+++ and this one has more on it
""")
    s.text('content/pages/p.md', """\
+++
# leading comment before any key
title = "Page with comments"
slug = "commented"
draft=false
+++
Page body.
""")
    s.templates(THEME_TOML)
    return s


def markdown_blocks():
    s = SiteSpec('markdown_blocks')
    s.config(BASE_CONFIG)
    s.post('blocks.md', [('title', 'Block structure'), ('date', '2020-03-01'),
                         ('tags', ['Markdown'])], """\
# A heading

Setext heading
=============

Another one
-----------

A paragraph with
a soft line break.

* a bullet
* another bullet
  with a continuation line

1. first
2. second
   1. nested
   2. also nested

> A block quote
> spanning lines.
>
> > Nested quote.

```python
def f(x):
    return x * 2
```

    an indented code block
    second line

***

## Heading with closing hashes ##
""")
    s.post('lists.md', [('title', 'Loose and tight lists'), ('date', '2020-03-02'),
                        ('tags', ['Markdown'])], """\
Tight:

- one
- two
- three

Loose:

- one

- two

Mixed markers restart lists:

+ plus one
+ plus two

- dash one

Ordered starting at 5:

5. five
6. six
""")
    s.templates(THEME_MIN)
    return s


def markdown_inline():
    s = SiteSpec('markdown_inline')
    s.config(BASE_CONFIG)
    s.post('inline.md', [('title', 'Inline constructs'), ('date', '2020-04-01'),
                         ('tags', ['Markdown'])], r"""
*emphasis*, _also emphasis_, **strong**, __also strong__, ***both***.

`code span`, ``a span with ` inside``, and `` `padded` ``.

A [link](https://example.com/a?b=c&d=e "with a title") and
an ![image](/img/pic.png "alt title") and a [bare](<https://example.com/x y>).

Autolinks: <https://example.com/auto> and <someone@example.com>.

Entities: &amp; &lt; &gt; &quot; &#65; &#x41; and a non-entity &notreal;.

Backslash escapes: \*not emphasis\*, \[not a link\], \\ and \`.

A hard break at the end of this line\
and the next line.

A hard break with two spaces
and the next line.
""".lstrip('\n'))
    s.templates(THEME_MIN)
    return s


def template_inheritance():
    s = SiteSpec('template_inheritance')
    s.config([('title', 'Layered'), ('base_url', 'https://layers.example'),
              ('author', 'L. Ayer'), ('posts_per_page', 2)])
    s.post('one.md', [('title', 'One'), ('date', '2021-01-01'), ('tags', ['X'])], 'One.\n')
    s.post('two.md', [('title', 'Two'), ('date', '2021-01-02'), ('tags', ['X', 'Y'])], 'Two.\n')
    s.page('info.md', [('title', 'Info')], 'Info page.\n')
    s.templates(THEME_ARCHIVE)
    return s


def template_filters():
    s = SiteSpec('template_filters')
    s.config([('title', '  Filter Lab  '), ('base_url', 'https://filters.example'),
              ('author', "O'Reilly & Sons"), ('posts_per_page', 2),
              ('keywords', ['delta', 'alpha', 'charlie', 'bravo']),
              ('motto', 'a<b>c&d"e\'f'), ('count_text', '  42 apples')])
    s.post('one.md', [('title', 'Alpha & Omega'), ('date', '2021-02-03'),
                      ('tags', ['Math', 'Logic'])], 'First body.\n')
    s.post('two.md', [('title', 'Beta'), ('date', '2021-02-04'), ('tags', ['Logic'])],
           'Second body.\n')
    s.page('p.md', [('title', 'Plain page')], 'Plain.\n')
    filters = {
        'index.html': """\
title trimmed upper: {{ site.title|trim|upper }}
title lower: {{ site.title|lower|trim }}
motto escaped: {{ site.motto|escape }}
keywords sorted: {{ site.keywords|sort|join(", ") }}
keywords reversed: {{ site.keywords|reverse|join("/") }}
first/last: {{ site.keywords|first }} {{ site.keywords|last }}
length: {{ site.keywords|length }} {{ site.title|length }}
int: {{ site.count_text|int }} {{ site.posts_per_page|int }}
replace: {{ site.base_url|replace("https://", "") }}
default: {{ site.missing|default("fallback") }} {{ site.author|default("x") }}
reverse string: {{ site.author|reverse }}
slug chain: {{ posts|first|default("")|default("") is defined }}
maths: {{ 7 / 2 }} {{ 7 // 2 }} {{ 7 % 2 }} {{ 2 ** 10 }} {{ -7 // 2 }}
concat: {{ site.title|trim ~ "!" ~ pagination.total_posts }}
compare: {{ 1 < 2 }} {{ "a" > "b" }} {{ pagination.number == 1 }}
membership: {{ "alpha" in site.keywords }} {{ "z" in site.title }}
loop:{% for t in tags %} {{ loop.index }}/{{ loop.length }}:{{ t.name }}{% if loop.first %}(first){% endif %}{% if loop.last %}(last){% endif %}{% endfor %}
range:{% for i in range(1, 4) %} {{ i }}{% endfor %}
""",
        'post.html': """\
{% macro badge(text, kind="plain") %}[{{ kind }}:{{ text }}]{% endmacro -%}
{{ post.title|escape }}
{{ badge(post.slug) }} {{ badge(post.date, "date") }} {{ badge(kind="tags", text=post.tags|length) }}
{% set names = post.tags %}{% for t in names %}{{ t.name|lower }}{% if not loop.last %}+{% endif %}{% endfor %}
{{ post.content }}""",
        'page.html': "{{ page.title }}: {{ page.content|trim }}\n",
        'tag.html': """\
{{ tag.name }} = {{ tag.post_count }}
{%- for post in posts %}
{{ loop.index0 }} {{ post.title|replace(" ", "_") }}
{%- endfor %}
""",
        'tags.html': """\
{% if tags %}{{ tags|length }} tags{% else %}none{% endif %}
{% for t in tags %}{{ t.name }}={{ t.slug }} {% endfor %}
{% if "Logic" == tags|first|default("")|default("") %}?{% endif %}
""",
    }
    s.templates(filters)
    return s


def static_tree():
    s = SiteSpec('static_tree')
    s.config(BASE_CONFIG)
    s.post('a.md', [('title', 'With assets'), ('date', '2022-08-08')],
           'See the image.\n')
    s.text('static/robots.txt', ROBOTS)
    s.text('static/css/site.css', SITE_CSS)
    s.text('static/css/print.css', '@media print { nav { display: none; } }\n')
    s.text('static/js/app.js', 'console.log("hi");\n')
    s.text('static/deep/deeper/deepest/note.txt', 'deep file\n')
    s.binary('static/img/pixel.png', PNG_1X1)
    s.binary('static/data/bytes.bin', bytes(range(256)))
    s.text('static/.nojekyll', '')
    s.text('static/.well-known/security.txt',
           'Contact: mailto:security@example.com\n')
    s.binary('static/data/empty.bin', b'')
    s.templates(THEME_MIN)
    return s


def empty_bodies():
    s = SiteSpec('empty_bodies')
    s.config(BASE_CONFIG)
    s.text('content/posts/empty.md', '+++\ntitle = "Empty body"\ndate = "2020-05-05"\n+++\n')
    s.text('content/posts/blank.md',
           '+++\ntitle = "Blank body"\ndate = "2020-05-06"\n+++\n\n   \n\t\n\n')
    s.post('normal.md', [('title', 'Normal'), ('date', '2020-05-07')], 'Text.\n')
    s.text('content/pages/nothing.md', '+++\ntitle = "Nothing"\n+++\n')
    s.templates(THEME_MIN)
    return s


def excerpt_forms():
    s = SiteSpec('excerpt_forms')
    s.config(BASE_CONFIG)
    s.post('para.md', [('title', 'Paragraph first'), ('date', '2020-06-01')],
           'First paragraph, *with* emphasis.\nStill the first paragraph.\n\nSecond paragraph.\n')
    s.post('heading.md', [('title', 'Heading first'), ('date', '2020-06-02')],
           '# A heading\n\nThen a paragraph.\n')
    s.post('list.md', [('title', 'List first'), ('date', '2020-06-03')],
           '- one\n- two\n\nAfter the list.\n')
    s.post('leading-blanks.md', [('title', 'Leading blanks'), ('date', '2020-06-04')],
           '\n\n   \nThe real first block.\n\nAnd more.\n')
    s.post('fence.md', [('title', 'Fence first'), ('date', '2020-06-05')],
           '```\nnot closed inside the excerpt\n```\n\nAfter.\n')
    s.post('single.md', [('title', 'Single block'), ('date', '2020-06-06')],
           'The whole body is one block.\n')
    s.post('split-fence.md', [('title', 'Fence with a blank line'), ('date', '2020-06-07')],
           '```text\nline one\n\nline three\n```\n\nAfter the fence.\n')
    s.post('ws-separator.md', [('title', 'Whitespace separator'), ('date', '2020-06-08')],
           'First block line one.\nAnd line two.\n   \t \n'
           'A second block, after a line of spaces and tabs.\n')
    s.post('ws-leading.md', [('title', 'Whitespace lead'), ('date', '2020-06-09')],
           ' \t\n\nThe block after a whitespace-only line.\n\nTail.\n')
    s.templates(THEME_MIN)
    return s


def unicode_site():
    s = SiteSpec('unicode')
    s.config([('title', 'Ünïcødé Blög'), ('base_url', 'https://xn--u.example'),
              ('author', '日本語 の 著者'), ('posts_per_page', 2)])
    s.post('cafe.md', [('title', 'Café société'), ('date', '2021-11-01'),
                       ('tags', ['Français', 'Ça va']), ('slug', 'cafe-societe')],
           'Une phrase avec des accents : é, è, ê, ë, ç, à, ù.\n\n'
           'Et un peu d’emphase **forte** ici.\n')
    s.post('kana.md', [('title', 'かなとカナ'), ('date', '2021-11-02'),
                       ('tags', ['日本語 notes']), ('slug', 'kana')],
           'ひらがな と カタカナ の テスト。\n\n段落が二つあります。\n')
    s.post('emoji.md', [('title', 'Emoji 🎉 party'), ('date', '2021-11-03'),
                        ('tags', ['Ça va']), ('slug', 'emoji')],
           'Emoji in the body: 🎉 🚀 🐙.\n')
    s.page('a-propos.md', [('title', 'À propos'), ('slug', 'a-propos')],
           '# À propos\n\nQuelques mots.\n')
    s.templates(THEME_MIN)
    return s


def xml_escaping():
    s = SiteSpec('xml_escaping')
    s.config([('title', 'Tom & Jerry <Blog>'),
              ('base_url', 'https://amp.example/s?q="x"&n=1'),
              ('author', 'A & B "Co" <team>'), ('posts_per_page', 5)])
    s.post('amp.md', [('title', 'Fish & Chips < Pie > Mash'), ('date', '2021-03-01'),
                      ('tags', ['R&D', 'A<B'])],
           'Ampersands &amp; angles &lt;like this&gt; and a "quoted" word.\n\n'
           'A [link](https://example.com/?a=1&amp;b=2) with an escaped ampersand.\n')
    s.post('quotes.md', [('title', 'He said "hello"'), ('date', '2021-03-02')],
           'Straight "quotes" and an apostrophe’s worth of text.\n')
    s.templates(THEME_MIN)
    return s


def untagged():
    s = SiteSpec('untagged')
    s.config(BASE_CONFIG)
    for i in range(4):
        s.post('n%d.md' % i, [('title', 'Untagged %d' % i),
                              ('date', '2020-07-0%d' % (i + 1))],
               'No tags on this one.\n')
    s.text('content/posts/explicit-empty.md',
           '+++\ntitle = "Explicitly empty tags"\ndate = "2020-07-09"\ntags = []\n+++\n'
           'An empty tag array.\n')
    s.templates(THEME_MIN)
    return s


def one_per_page():
    s = SiteSpec('one_per_page')
    s.config([('title', 'Slow Reader'), ('base_url', 'https://slow.example'),
              ('author', 'S. Lowe'), ('posts_per_page', 1)])
    for i in range(5):
        s.post('s%d.md' % i, [('title', 'Step %d' % i),
                              ('date', '2020-08-%02d' % (i + 1)),
                              ('tags', ['Steps'])],
               'Step number %d.\n' % i)
    s.templates(THEME_BLOG)
    s.text('static/css/site.css', SITE_CSS)
    return s


def per_page_larger_than_posts():
    s = SiteSpec('per_page_larger')
    s.config([('title', 'Roomy'), ('base_url', 'https://roomy.example'),
              ('author', 'R. Oomy'), ('posts_per_page', 100)])
    for i in range(3):
        s.post('r%d.md' % i, [('title', 'Roomy %d' % i),
                              ('date', '2020-09-0%d' % (i + 1)),
                              ('tags', ['Roomy'])],
               'Plenty of room.\n')
    s.templates(THEME_MIN)
    return s


def many_pages():
    s = SiteSpec('many_pages')
    s.config(BASE_CONFIG)
    s.post('only.md', [('title', 'Only post'), ('date', '2020-10-10'), ('tags', ['Solo'])],
           'One post, many pages.\n')
    for slug, title in [('zeta', 'Zeta page'), ('alpha', 'Alpha page'),
                        ('middle', 'Middle page'), ('beta-2', 'Beta two')]:
        s.page(slug + '.md', [('title', title)],
               '# %s\n\nContent of %s.\n' % (title, slug))
    s.page('aardvark.md', [('title', 'Last page'), ('slug', 'zulu')],
           '# Last page\n\nThe file name sorts first, the slug sorts last.\n')
    s.templates(THEME_MIN)
    return s


def tag_ordering():
    s = SiteSpec('tag_ordering')
    s.config(BASE_CONFIG)
    s.post('a.md', [('title', 'A'), ('date', '2020-11-01'),
                    ('tags', ['Zebra', 'apple pie', 'Ångström'])], 'A.\n')
    s.post('b.md', [('title', 'B'), ('date', '2020-11-02'),
                    ('tags', ['C Sharp', 'apple pie'])], 'B.\n')
    s.post('c.md', [('title', 'C'), ('date', '2020-11-03'),
                    ('tags', ['  spaced  out  ', 'Zebra', 'Zebra'])], 'C.\n')
    s.post('d.md', [('title', 'D'), ('date', '2020-11-04'),
                    ('tags', ['Zebra', 'apple pie', 'Zebra'])],
           'A repeated tag keeps its first position.\n')
    s.templates(THEME_MIN)
    return s


def rich_blog():
    s = SiteSpec('rich_blog')
    s.config([('title', 'The Rich Blog'), ('base_url', 'https://rich.example/site'),
              ('author', 'Rich Text'), ('posts_per_page', 2),
              ('description', 'A small blog with a real layout.')])
    bodies = [
        ('Getting started', '2022-02-01', ['Guides', 'Tooling'], """\
Welcome to the blog. This first post explains **what** you will find here.

The plan is simple:

1. write things down,
2. publish them,
3. forget about them.

> Writing is thinking, slowed down enough to be checked.

Next time: a look at the `build` command.
"""),
        ('The build command', '2022-02-14', ['Tooling'], """\
The `build` command turns a source tree into a site.

```sh
sitegen ./src ./out
```

It reads `site.toml`, renders every post through the templates, and copies
everything under `static/` verbatim.

See the [documentation](https://example.com/docs) for the full list of
options.
"""),
        ('On slow software', '2022-03-08', ['Essays', 'aside'], """\
Software that is *slow to write* is often fast to read.

There is a kind of patience in a program that does one thing per line,
in order, with no cleverness at all. It is not fashionable. It is very
easy to debug.

- it fits in your head
- it fits on a screen
- it fits in a talk

That is the whole argument.
"""),
        ('A note on typography', '2022-04-02', ['Essays', 'Design'], """\
Three rules:

1. one typeface is usually enough
2. measure beats size
3. whitespace is not empty

![A diagram](/img/pixel.png "the diagram")

Read the classics if you disagree.
"""),
        ('Release 1.0', '2022-05-20', ['Tooling', 'Guides'], """\
Version 1.0 is out.

Changes since 0.9:

- pagination on the index
- Atom feed
- tag pages

Upgrade with:

    pip install --upgrade sitegen

Thanks to everybody who sent patches.
"""),
    ]
    for title, date, tags, body in bodies:
        s.post(ref.slugify(title) + '.md',
               [('title', title), ('date', date), ('tags', tags)], body)
    s.page('about.md', [('title', 'About')], """\
# About

This site is generated from Markdown by a program with no dependencies.

Contact: <hello@example.com>
""")
    s.page('colophon.md', [('title', 'Colophon')], """\
# Colophon

Set in whatever your browser prefers.
""")
    s.templates(THEME_BLOG)
    s.text('static/css/site.css', SITE_CSS)
    s.text('static/robots.txt', ROBOTS)
    s.binary('static/img/pixel.png', PNG_1X1)
    return s


# ---------------------------------------------------------------------------
# Corpus-driven sites
# ---------------------------------------------------------------------------

def read_corpus(name):
    with open(os.path.join(CORPUS, name), encoding='utf-8') as f:
        return f.read()


def unique_slug(base, used):
    slug = base or 'untitled'
    if slug in used:
        n = 2
        while '%s-%d' % (slug, n) in used:
            n += 1
        slug = '%s-%d' % (slug, n)
    used.add(slug)
    return slug


def emphasize_leading_caps(paragraph):
    """Marks the leading run of capitalised words as strong emphasis.

    The markers are only inserted when both neighbours are ASCII, which keeps
    the emphasis-flanking guarantee of the Markdown subset satisfied.
    """
    m = re.search(r'\b[A-Z]{2,}(?:[ ][A-Z]{2,})*\b', paragraph)
    if not m or m.start() > 40:
        return paragraph
    before = paragraph[m.start() - 1] if m.start() else ''
    after = paragraph[m.end()] if m.end() < len(paragraph) else ''
    if (before and ord(before) > 127) or (after and ord(after) > 127):
        return paragraph
    return paragraph[:m.start()] + '**' + m.group(0) + '**' + paragraph[m.end():]


def paragraphs(text):
    return [p.strip('\n') for p in re.split(r'\n[ \t]*\n', text) if p.strip()]


AESOP_KEYWORDS = [
    ('Lion', 'Lions'), ('Wolf', 'Wolves'), ('Fox', 'Foxes'), ('Ass', 'Asses'),
    ('Dog', 'Dogs'), ('Frog', 'Frogs'), ('Bear', 'Bears'), ('Goat', 'Goats'),
    ('Horse', 'Horses'), ('Mouse', 'Mice'), ('Eagle', 'Eagles'), ('Crow', 'Crows'),
    ('Sheep', 'Sheep'), ('Snake', 'Snakes'), ('Ox', 'Oxen'), ('Boy', 'Boys'),
    ('Man', 'Men'), ('Hare', 'Hares'), ('Cat', 'Cats'), ('Fisherman', 'Fishermen'),
    ('Bee', 'Bees'), ('Stag', 'Stags'), ('Monkey', 'Monkeys'), ('Farmer', 'Farmers'),
    ('Traveler', 'Travelers'), ('Shepherd', 'Shepherds'), ('Hunter', 'Hunters'),
    ('Jupiter', 'Jupiter'), ('Tree', 'Trees'), ('Bird', 'Birds'), ('Kid', 'Kids'),
    ('Swan', 'Swans'), ('Widow', 'Widows'), ('Thief', 'Thieves'),
]


def aesop_site():
    text = read_corpus('aesop.txt')
    chunks = [c.strip('\n') for c in re.split(r'\n{4,}', text)]
    fables = []
    for chunk in chunks:
        if not chunk or chunk.startswith('AESOP'):
            continue
        lines = chunk.split('\n')
        title = lines[0].strip()
        body = '\n'.join(lines[1:]).strip('\n')
        if title and body:
            fables.append((title, body))
    assert len(fables) >= 300, len(fables)

    s = SiteSpec('aesop_fables')
    s.config([('title', 'Three Hundred Fables'),
              ('base_url', 'https://fables.example'),
              ('author', 'George Fyler Townsend'),
              ('posts_per_page', 10),
              ('description', 'Aesop, literally translated from the Greek.'),
              ('keywords', ['fables', 'aesop', 'morals'])])
    used = set()
    start = datetime.date(2019, 1, 1)
    for index, (title, raw) in enumerate(fables):
        slug = unique_slug(ref.slugify(title), used)
        lower = title.lower()
        tags = [plural for single, plural in AESOP_KEYWORDS
                if re.search(r'\b%ss?\b' % single.lower(), lower)]
        if not tags:
            tags = ['Fables']
        paras = paragraphs(raw)
        paras[0] = emphasize_leading_caps(paras[0])
        if len(paras) > 1 and paras[-1].lstrip().startswith('“'):
            moral = paras.pop()
            paras.append('## The moral')
            paras.append('\n'.join('> ' + line for line in moral.split('\n')))
        if index % 5 == 0:
            paras.append('Read the whole collection at '
                         '[Project Gutenberg](https://www.gutenberg.org/ebooks/21).')
        if index % 7 == 0:
            paras.append('Themes:\n\n' + '\n'.join('- %s' % t.lower() for t in tags))
        body = '\n\n'.join(paras) + '\n'
        date = (start + datetime.timedelta(days=index // 2)).isoformat()
        s.post(slug + '.md',
               [('title', title), ('date', date), ('slug', slug), ('tags', tags)],
               body)
    s.page('about.md', [('title', 'About this collection')], """\
# About

Three hundred fables attributed to Aesop, in the literal translation of the
Rev. George Fyler Townsend.

The text is in the public domain.
""")
    s.page('sources.md', [('title', 'Sources')], """\
# Sources

- [Project Gutenberg eBook 21](https://www.gutenberg.org/ebooks/21)

Each fable is one post. Tags are the animals that appear in the title.
""")
    s.templates(THEME_BLOG)
    s.text('static/css/site.css', SITE_CSS)
    s.text('static/robots.txt', ROBOTS)
    return s


BACON_TOPICS = [
    ('Virtue', ['truth', 'goodness', 'nature', 'honour', 'praise', 'judicature']),
    ('Power', ['empire', 'kingdom', 'seditions', 'nobility', 'great place', 'faction']),
    ('Money', ['riches', 'usury', 'expense', 'plantations', 'building']),
    ('People', ['friendship', 'followers', 'suitors', 'parents', 'marriage', 'love']),
    ('Mind', ['studies', 'wisdom', 'cunning', 'seeming wise', 'discourse', 'custom']),
    ('Fortune', ['fortune', 'delays', 'prophecies', 'vicissitude', 'fame', 'ambition']),
    ('Death', ['death', 'adversity', 'revenge', 'envy', 'anger', 'suspicion']),
]


def bacon_site():
    text = read_corpus('bacon.txt')
    essays = []
    for chunk in re.split(r'\n{4,}', text):
        chunk = chunk.strip('\n')
        if not chunk:
            continue
        lines = chunk.split('\n')
        title = lines[0].strip()
        body = '\n'.join(lines[1:]).strip('\n')
        if title.startswith('Of ') and body:
            essays.append((title, body))
    assert len(essays) == 59, len(essays)

    s = SiteSpec('bacon_essays')
    s.config([('title', 'Essays, Civil and Moral'),
              ('base_url', 'https://bacon.example'),
              ('author', 'Francis Bacon'),
              ('posts_per_page', 6),
              ('subtitle', 'of Francis Ld. Verulam, Viscount St. Albans'),
              ('since', '1597'),
              ('keywords', ['counsel', 'essays', 'morals', 'civil'])])
    used = set()
    start = datetime.date(1597, 1, 7)
    for index, (title, raw) in enumerate(essays):
        slug = unique_slug(ref.slugify(title), used)
        lower = title.lower()
        tags = [topic for topic, words in BACON_TOPICS
                if any(w in lower for w in words)]
        if not tags:
            tags = ['Miscellany']
        paras = paragraphs(raw)
        paras[0] = emphasize_leading_caps(paras[0])
        if index % 4 == 0:
            paras.insert(1, '*Written in the manner of the age.*')
        body = '\n\n'.join(paras) + '\n'
        date = (start + datetime.timedelta(days=index * 9)).isoformat()
        s.post('%02d-%s.md' % (index, slug),
               [('title', title), ('date', date), ('slug', slug), ('tags', tags)],
               body)
    s.page('colophon.md', [('title', 'Colophon')], """\
# Colophon

Text from Project Gutenberg, spelling as printed.
""")
    s.templates(THEME_ESSAY)
    return s


FEDERALIST_TOPICS = [
    ('Union', ['union', 'confederacy', 'confederation']),
    ('Taxation', ['taxation', 'revenue', 'taxes', 'expenses']),
    ('Judiciary', ['judiciary', 'judicial', 'courts']),
    ('Senate', ['senate']),
    ('Executive', ['executive', 'president']),
    ('Militia', ['militia', 'army', 'military', 'navy', 'force']),
    ('Commerce', ['commerce', 'trade']),
    ('Powers', ['powers', 'power', 'authority']),
    ('House', ['house of representatives', 'representatives']),
    ('States', ['state governments', 'states', 'state']),
]

MONTH_NAMES = ('January February March April May June July August September '
               'October November December').split()
FED_DATE_RE = re.compile(r'(%s)\s+(\d{1,2}),\s+(\d{4})' % '|'.join(MONTH_NAMES))
FED_AUTHOR_RE = re.compile(r'(?m)^(HAMILTON AND MADISON|MADISON, with HAMILTON|'
                           r'HAMILTON OR MADISON|HAMILTON|MADISON|JAY)[ \t]*$')
FED_AUTHOR_TAGS = {
    'HAMILTON': ['Hamilton'],
    'MADISON': ['Madison'],
    'JAY': ['Jay'],
    'HAMILTON AND MADISON': ['Hamilton', 'Madison'],
    'MADISON, with HAMILTON': ['Madison', 'Hamilton'],
    'HAMILTON OR MADISON': ['Hamilton', 'Madison'],
}


def federalist_site():
    text = read_corpus('federalist.txt')
    parts = re.split(r'(?m)^FEDERALIST\.? No\. ', text)[1:]
    papers = []
    for part in parts:
        lines = part.split('\n')
        number = int(lines[0].strip())
        rest = [line for line in lines[1:]]
        subject = next(line.strip() for line in rest if line.strip())
        date_match = FED_DATE_RE.search(part[:500])
        author_match = FED_AUTHOR_RE.search(part)
        date = '%s-%02d-%02d' % (date_match.group(3),
                                 MONTH_NAMES.index(date_match.group(1)) + 1,
                                 int(date_match.group(2)))
        body = part[author_match.end():].strip('\n')
        papers.append((number, subject, date, author_match.group(1), body))
    assert len(papers) == 85, len(papers)

    s = SiteSpec('federalist_papers')
    s.config([('title', 'The Federalist'),
              ('base_url', 'https://federalist.example'),
              ('author', 'Publius'),
              ('posts_per_page', 8)])
    used = set()
    for number, subject, date, author, raw in papers:
        slug = unique_slug('federalist-%d' % number, used)
        tags = list(FED_AUTHOR_TAGS[author])
        lower = subject.lower()
        for topic, words in FEDERALIST_TOPICS:
            if any(w in lower for w in words):
                tags.append(topic)
                break
        paras = paragraphs(raw)
        paras[0] = emphasize_leading_caps(paras[0])
        paras.insert(0, '*%s*' % subject)
        body = '\n\n'.join(paras) + '\n'
        s.post('%03d.md' % number,
               [('title', 'No. %d: %s' % (number, subject)), ('date', date),
                ('slug', slug), ('tags', tags)],
               body)
    s.page('index-of-papers.md', [('title', 'Index'), ('slug', 'index-of-papers')],
           '# Index\n\nThe papers are listed newest first on the front page.\n')
    s.templates(THEME_ARCHIVE)
    s.text('static/robots.txt', ROBOTS)
    return s


# ---------------------------------------------------------------------------
# Guarantee checks on Markdown bodies
# ---------------------------------------------------------------------------

HTML5_NAMES = {name[:-1] for name in html.entities.html5 if name.endswith(';')}
ALLOWED_ENTITIES = {'amp', 'lt', 'gt', 'quot'}
ENTITY_RE = re.compile(r'&([A-Za-z][A-Za-z0-9]*);')
REFDEF_RE = re.compile(r'(?m)^(?:[ \t]*(?:>|[-+*][ \t]|\d{1,9}[.)][ \t]))*[ \t]*\[[^\]]*\][ \t]*:')
EMPTY_ITEM_RE = re.compile(r'(?m)^(?:[ \t]{0,3}>[ \t]?)*[ \t]{0,3}(?:[-+*]|\d{1,9}[.)])[ \t]*$')
DELIM_RUN_RE = re.compile(r'\*+|_+')
LT_RE = re.compile(r'<(?=[A-Za-z/!?])')

failures = []


def fail(message):
    failures.append(message)
    print('FAIL: ' + message)


def check_markdown_guarantees(where, text):
    for ch in text:
        code = ord(ch)
        if code == 0 or ch == '\r' or ch == '\x7f' or (code < 32 and ch not in '\t\n'):
            fail('%s: forbidden control character %r' % (where, ch))
            return
    for m in ENTITY_RE.finditer(text):
        if m.group(1) in HTML5_NAMES and m.group(1) not in ALLOWED_ENTITIES:
            fail('%s: named entity &%s; outside the supported four' % (where, m.group(1)))
    m = REFDEF_RE.search(text)
    if m:
        fail('%s: looks like a link reference definition: %r' % (where, m.group(0)))
    m = EMPTY_ITEM_RE.search(text)
    if m:
        fail('%s: empty list item %r' % (where, m.group(0)))
    if re.search('`{101,}', text) or re.search('(?m)^[ \t]*([`~])\\1{100,}', text):
        fail('%s: over-long backtick run or fence' % where)
    for m in DELIM_RUN_RE.finditer(text):
        for ch in (text[m.start() - 1] if m.start() else '',
                   text[m.end()] if m.end() < len(text) else ''):
            if ch and ord(ch) > 127 and unicodedata.category(ch)[0] in 'ZPSC':
                fail('%s: non-ASCII %s next to a delimiter run'
                     % (where, unicodedata.category(ch)))
    for m in LT_RE.finditer(text):
        i = m.start() + 1
        if (ref.markdown.AUTOLINK_URI_RE.match(text, i)
                or ref.markdown.AUTOLINK_EMAIL_RE.match(text, i)):
            continue
        # The `<...>` form of an inline link or image destination is the other
        # position where the Markdown subset allows a `<` before a letter.
        if text[max(0, m.start() - 2):m.start()] == '](' and '>)' in text[i:i + 200]:
            continue
        fail('%s: %r is not an autolink and could start raw HTML'
             % (where, text[m.start():m.start() + 20]))


# ---------------------------------------------------------------------------
# Oracles
# ---------------------------------------------------------------------------

JINJA_ORACLE = r'''
import json, sys
from jinja2 import Environment, DictLoader, StrictUndefined

data = json.load(open(sys.argv[1], encoding='utf-8'))
env = Environment(loader=DictLoader(data['templates']), undefined=StrictUndefined,
                  autoescape=False, trim_blocks=False, lstrip_blocks=False,
                  keep_trailing_newline=False)
bad = 0
for record in data['renders']:
    produced = env.get_template(record['template']).render(**record['context'])
    if produced != record['output']:
        bad += 1
        print('MISMATCH %s (%s)' % (record['path'], record['template']))
        for i in range(min(len(produced), len(record['output'])) + 1):
            if produced[i:i + 1] != record['output'][i:i + 1]:
                print('  at %d jinja2=%r reference=%r'
                      % (i, produced[max(0, i - 80):i + 80],
                         record['output'][max(0, i - 80):i + 80]))
                break
        if bad >= 3:
            break
sys.exit(1 if bad else 0)
'''


def check_toml_oracle(where, text, parsed):
    """Re-parses a TOML-subset document with tomllib and compares."""
    import tomllib
    try:
        expected = tomllib.loads(text)
    except Exception as exc:                                  # pragma: no cover
        fail('%s: tomllib rejected the document: %s' % (where, exc))
        return
    if expected != parsed:
        fail('%s: tomllib produced %r, the reference produced %r'
             % (where, expected, parsed))


def check_cmark_oracle(where, source, produced):
    result = subprocess.run([CMARK], input=source.encode('utf-8'),
                            stdout=subprocess.PIPE)
    if result.returncode != 0:
        fail('%s: cmark exited %d' % (where, result.returncode))
        return
    expected = result.stdout.decode('utf-8')
    if expected != produced:
        fail('%s: cmark produced %r, the reference produced %r'
             % (where, expected[:200], produced[:200]))


def raw_templates(input_dir):
    """The template files unmodified, for the Jinja2 oracle to strip itself."""
    directory = os.path.join(input_dir, 'templates')
    return {name: ref.read_text(os.path.join(directory, name))
            for name in sorted(os.listdir(directory))
            if name.endswith('.html') and os.path.isfile(os.path.join(directory, name))}


def check_jinja_oracle(name, templates, renders):
    with tempfile.TemporaryDirectory(prefix='sitegen_oracle_') as tmp:
        script = os.path.join(tmp, 'oracle.py')
        with open(script, 'w', encoding='utf-8') as f:
            f.write(JINJA_ORACLE)
        payload = os.path.join(tmp, 'data.json')
        with open(payload, 'w', encoding='utf-8') as f:
            json.dump({'templates': templates, 'renders': renders}, f, ensure_ascii=False)
        result = subprocess.run([VENV_PYTHON, script, payload],
                                capture_output=True, text=True)
        if result.returncode != 0:
            fail('%s: Jinja2 disagrees with the reference renderer:\n%s'
                 % (name, (result.stdout + result.stderr)[:2000]))


SLUG_RE = re.compile(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$')
MEMBER_BLOCKLIST = set('items keys values get pop update copy clear count '
                       'index append'.split())
INT64_MIN, INT64_MAX = -2 ** 63, 2 ** 63 - 1


def check_toml_values(where, parsed):
    """Integers fit in 64 bits and no string carries a lone surrogate."""
    def check_string(value):
        for ch in value:
            if 0xD800 <= ord(ch) <= 0xDFFF:
                fail('%s: string contains a surrogate code point' % where)
    for key, value in parsed.items():
        if isinstance(value, bool):
            continue
        if isinstance(value, int) and not INT64_MIN <= value <= INT64_MAX:
            fail('%s: integer %r does not fit in a signed 64-bit integer' % (where, value))
        if isinstance(value, str):
            check_string(value)
        if isinstance(value, list):
            for item in value:
                check_string(item)


def check_site_guarantees(name, input_dir):
    """Checks the guarantees the SPEC makes about every test input."""
    site = ref.Site(input_dir)
    generated = {'index.html', 'feed.xml', 'sitemap.xml',
                 os.path.join('tags', 'index.html')}

    def claim(path, what):
        if path in generated:
            fail('%s: %s writes %s, which is already generated' % (name, what, path))
        generated.add(path)

    for number in range(2, site.total_pages + 1):
        claim(os.path.join('page', str(number), 'index.html'), 'index page %d' % number)
    for post in site.posts:
        if not SLUG_RE.match(post['slug']):
            fail('%s: post slug %r is not [a-z0-9]([a-z0-9-]*[a-z0-9])?'
                 % (name, post['slug']))
        claim(os.path.join('posts', post['slug'], 'index.html'), 'post %r' % post['slug'])
    for page in site.pages:
        if not SLUG_RE.match(page['slug']):
            fail('%s: page slug %r is not [a-z0-9]([a-z0-9-]*[a-z0-9])?'
                 % (name, page['slug']))
        if page['slug'] in ('posts', 'page', 'tags'):
            fail('%s: page slug %r is reserved' % (name, page['slug']))
        claim(os.path.join(page['slug'], 'index.html'), 'page %r' % page['slug'])
    for tag in site.tag_names:
        slug = ref.slugify(tag)
        if not SLUG_RE.match(slug):
            fail('%s: tag %r has slug %r, which is not [a-z0-9]([a-z0-9-]*[a-z0-9])?'
                 % (name, tag, slug))
        claim(os.path.join('tags', slug, 'index.html'), 'tag %r' % tag)

    static_root = os.path.join(input_dir, 'static')
    if os.path.isdir(static_root):
        for dirpath, _, filenames in os.walk(static_root):
            for filename in filenames:
                rel = os.path.relpath(os.path.join(dirpath, filename), static_root)
                if rel in generated:
                    fail('%s: static file %s collides with a generated file' % (name, rel))

    for key in site.config:
        if key in ('posts', 'pagination', 'post', 'page', 'tag', 'tags'):
            fail('%s: site key %r shadows a context variable' % (name, key))
        if key in MEMBER_BLOCKLIST or key.startswith('_'):
            fail('%s: site key %r is not usable as a template member' % (name, key))
    check_toml_values('%s/site.toml' % name, site.config)


def check_xml(name, path):
    try:
        ET.parse(path)
    except ET.ParseError as exc:
        fail('%s: %s is not well-formed XML: %s' % (name, os.path.basename(path), exc))


# ---------------------------------------------------------------------------
# Driving the reference and checking one site
# ---------------------------------------------------------------------------

def write_site(spec, root):
    for rel, data in sorted(spec.files.items()):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as f:
            f.write(data)


def check_content_oracles(name, input_dir):
    """Re-parses every TOML document and re-converts every body with the oracles."""
    site_toml = os.path.join(input_dir, 'site.toml')
    text = ref.read_text(site_toml)
    check_toml_oracle('%s/site.toml' % name, text, ref.parse_toml(text))

    for kind in ('posts', 'pages'):
        directory = os.path.join(input_dir, 'content', kind)
        for filename in ref.list_markdown(directory):
            where = '%s/content/%s/%s' % (name, kind, filename)
            raw = ref.read_text(os.path.join(directory, filename))
            front, body = ref.split_front_matter(raw, where)
            check_toml_oracle(where, front, ref.parse_toml(front))
            check_toml_values(where, ref.parse_toml(front))
            check_markdown_guarantees(where, body)
            check_cmark_oracle(where, body, ref.markdown.convert(body))
            if kind == 'posts':
                excerpt = ref.excerpt_source(body)
                if excerpt != body:
                    check_cmark_oracle(where + ' (excerpt)', excerpt,
                                       ref.markdown.convert(excerpt))


def build_case(number, spec):
    case = os.path.join(TESTS, '%03d_%s' % (number, spec.name))
    input_dir = os.path.join(case, 'input')
    expected_dir = os.path.join(case, 'expected')
    shutil.rmtree(case, ignore_errors=True)
    os.makedirs(input_dir)
    write_site(spec, input_dir)

    renders = []

    def hook(template, context, rel_path, output):
        renders.append({'template': template, 'context': context,
                        'path': rel_path, 'output': output})

    ref.generate(input_dir, expected_dir, hook)

    check_content_oracles(spec.name, input_dir)
    check_site_guarantees(spec.name, input_dir)
    check_jinja_oracle(spec.name, raw_templates(input_dir), renders)
    check_xml(spec.name, os.path.join(expected_dir, 'feed.xml'))
    check_xml(spec.name, os.path.join(expected_dir, 'sitemap.xml'))

    files = sum(len(names) for _, _, names in os.walk(expected_dir))
    size = sum(os.path.getsize(os.path.join(dp, n))
               for dp, _, names in os.walk(expected_dir) for n in names)
    print('%-34s %4d output files %8.1f KB' % (os.path.basename(case), files, size / 1024))


def main():
    sys.setrecursionlimit(20000)
    if not os.path.exists(CMARK):
        print('cmark not found at %s' % CMARK)
        return 2
    if not os.path.exists(VENV_PYTHON):
        print('oracle venv python not found at %s' % VENV_PYTHON)
        return 2

    for builder in (minimal, no_posts, drafts, single_tag, page_tag_same_slug,
                    pagination_exact, pagination_remainder, date_ties, slug_override,
                    toml_edge, markdown_blocks, markdown_inline, template_inheritance,
                    template_filters, static_tree, empty_bodies, excerpt_forms,
                    unicode_site, xml_escaping, untagged, one_per_page,
                    per_page_larger_than_posts, many_pages, tag_ordering, rich_blog,
                    bacon_site, federalist_site, aesop_site):
        add(builder())

    shutil.rmtree(TESTS, ignore_errors=True)
    os.makedirs(TESTS)
    for number, spec in enumerate(CASES, 1):
        build_case(number, spec)

    if failures:
        print('\n%d oracle disagreement(s); tests/ is not trustworthy' % len(failures))
        return 1
    print('\n%d test sites generated and cross-checked' % len(CASES))
    return 0


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'corpus/tests-notice.md'
TEST_LICENCES = [
    ('corpus/LICENSE',
     'LICENSE-corpus.txt'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


if __name__ == '__main__':
    rc = main()
    copy_licences()
    sys.exit(rc)
