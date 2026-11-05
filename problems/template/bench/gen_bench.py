#!/usr/bin/env python3
"""Generate the template performance benchmark inputs deterministically.

Writes bench/NNN_name.in (same layout as tests/) and bench/NNN_name.out via
reference/main.py. When Jinja2 is available (directly or through the
repository's .oracle-venv), every expected output is also cross-checked
against it with the same oracle that gen_tests.py uses, and the script aborts
on any disagreement.

The inputs keep to the scales the SPEC's "Sizes and performance" section
names: contexts of about 1 MB, template bodies of at most about 1 MB, macro
recursion over trees of a few thousand nodes, and macro recursion depth well
under 100. They obey every guarantee in the SPEC (ASCII strings for
upper/lower/sort, `set` never rebinding a visible name outside loops, no
blocks in loops or macros, etc.).
"""
import json
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
REF = os.path.join(PROBLEM, 'reference', 'main.py')
ORACLE_PY = os.path.join(PROBLEM, '..', '..', '.oracle-venv', 'bin', 'python')
# $LANGBENCH_ORACLE_PYTHON overrides; otherwise the main checkout's venv (a worktree may not have its own).
REPO_ORACLE_PY = os.environ.get('LANGBENCH_ORACLE_PYTHON') or os.path.normpath(
    os.path.join(PROBLEM, '..', '..', '..', '..', '..', '.oracle-venv', 'bin', 'python'))

WORDS = ['alpha', 'bravo', 'cedar', 'delta', 'ember', 'fjord', 'grove', 'harbor', 'iris', 'juniper',
         'kestrel', 'lumen', 'maple', 'nova', 'onyx', 'pine', 'quartz', 'raven', 'sierra', 'tundra',
         'umber', 'vale', 'willow', 'xenon', 'yarrow', 'zephyr']
BRANDS = ['Acme', 'Borealis', 'Corvid', 'Dunmore', 'Everline', 'Fathom', 'Glint', 'Hollis']
COLORS = ['red', 'blue', 'green', 'black', 'white', 'grey', 'navy', 'olive']
SIZES = ['XS', 'S', 'M', 'L', 'XL']
MATERIALS = ['cotton', 'wool', 'linen', 'steel', 'oak', 'resin', 'nylon']
# Descriptions are only printed, escaped or measured, so they may hold
# markup characters and non-ASCII text.
DESC_BITS = ['Durable & light', 'fits "true to size"', '<b>new</b> season', "the maker's pick",
             'café-grade finish', 'naïve charm', 'über soft', 'built for — everything',
             'rated 5★ by testers', 'ships in 2 days', 'limited run', 'eco > ego']


def make_input(context, templates):
    parts = [json.dumps(context, ensure_ascii=False, separators=(',', ':')), '\n--\n']
    for name, body in templates:
        assert not any(line.startswith('===') for line in body.split('\n')), name
        parts.append('=== ' + name + '\n' + body + '\n')
    return ''.join(parts)


# ---------------------------------------------------------------------------
# 001: product catalogue page (throughput)
# ---------------------------------------------------------------------------
def catalog_page(per_cat=(120, 170), n_featured=40):
    """A storefront page: inheritance layout, per-product include, macros, filters."""
    rng = random.Random(9001)
    categories = []
    pid = 0
    for c in range(20):
        cname = rng.choice(WORDS).capitalize() + ' ' + rng.choice(['Gear', 'Wear', 'Home', 'Tools', 'Outdoor'])
        products = []
        for _ in range(rng.randint(*per_cat)):
            pid += 1
            variants = [{'size': rng.choice(SIZES), 'color': rng.choice(COLORS), 'stock': rng.randint(0, 40)}
                        for _ in range(rng.randint(1, 4))]
            p = {
                'id': pid,
                'sku': '%s-%04d-%s' % (rng.choice(BRANDS)[:3].upper(), pid, rng.choice(COLORS)[:2].upper()),
                'name': ' '.join(rng.choice(WORDS) for _ in range(rng.randint(1, 3))),
                'brand': rng.choice(BRANDS),
                'price': rng.randint(199, 99999),
                'discount': rng.choice([0, 0, 0, 0.1, 0.15, 0.25, 0.3]),
                'rating': round(rng.uniform(1.0, 5.0), 1),
                'reviews': rng.randint(0, 5000),
                'tags': rng.sample(WORDS, rng.randint(0, 4)),
                'variants': variants,
                'attrs': {'material': rng.choice(MATERIALS), 'weight_g': rng.randint(50, 5000),
                          'origin': rng.choice(['US', 'DE', 'JP', 'VN', 'PT'])},
                'description': '  ' + '; '.join(rng.sample(DESC_BITS, rng.randint(1, 3))) + ' ',
            }
            if rng.random() < 0.2:
                p['badge'] = rng.choice(['sale', 'new', 'hot'])
            products.append(p)
        categories.append({'name': cname, 'slug': cname.lower().replace(' ', '-') + '-%d' % c,
                           'products': products})
    context = {'site': {'name': 'Northwind Outfitters', 'currency': 'USD', 'year': 2026},
               'categories': categories, 'featured': [rng.randint(1, pid) for _ in range(n_featured)],
               'brands': BRANDS, 'tagwords': WORDS}

    page = (
        '{% extends "layout" %}\n'
        '{% set page_title = "Catalogue" %}\n'
        '{% macro money(cents) %}${{ cents // 100 }}.{% if cents % 100 < 10 %}0{% endif %}{{ cents % 100 }}{% endmacro %}\n'
        '{% macro stars(r) %}{% for i in range(5) %}{% if i < r|int %}*{% else %}.{% endif %}{% endfor %}{% endmacro %}\n'
        '{% block title %}{{ page_title }} - {{ super() }}{% endblock %}\n'
        '{% block content %}\n'
        '{%- for cat in categories %}\n'
        '<section id="{{ cat.slug }}">\n'
        '  <h2>{{ loop.index }}. {{ cat.name|upper }} ({{ cat.products|length }} items)</h2>\n'
        '  {%- for p in cat.products %}\n'
        '  {% include "card" %}\n'
        '  {%- endfor %}\n'
        '</section>\n'
        '{%- endfor %}\n'
        '{% endblock %}\n'
        '{% block brands %}\n'
        '{%- for b in brands %}\n'
        '<h2>{{ b|upper }}</h2><ol>\n'
        '{%- for cat in categories %}{% for p in cat.products %}{% if p.brand == b %}'
        '<li>{{ p.name }} - {{ money(p.price) }}{% if p.rating >= 4 %} ({{ p.rating }}){% endif %}</li>{% endif %}'
        '{% endfor %}{% endfor %}\n'
        '</ol>\n'
        '{%- endfor %}\n'
        '{% endblock %}\n'
        '{% block related %}\n'
        '{%- for f in featured %}\n'
        '<div class="related">{% for cat in categories %}{% for p in cat.products %}{% if p.id == f %}'
        '{{ p.name|upper }} {{ money(p.price) }} in {{ cat.name }}{% endif %}{% endfor %}{% endfor %}</div>\n'
        '{%- endfor %}\n'
        '{% endblock %}\n'
        '{% block tagpages %}\n'
        '{%- for w in tagwords %}\n'
        '<h3>#{{ w }}</h3><p>{% for cat in categories %}{% for p in cat.products %}'
        '{% if w in p.tags %}{{ p.sku }} {% endif %}{% endfor %}{% endfor %}</p>\n'
        '{%- endfor %}\n'
        '{% endblock %}\n'
    )
    layout = (
        '<!doctype html>\n'
        '<html><head><title>{% block title %}{{ site.name }}{% endblock %}</title></head>\n'
        '<body>\n'
        '{% include "nav" %}\n'
        '<main>{% block content %}empty{% endblock %}</main>\n'
        '<aside>{% block brands %}{% endblock %}</aside>\n'
        '<aside>{% block related %}{% endblock %}</aside>\n'
        '<aside>{% block tagpages %}{% endblock %}</aside>\n'
        '<footer>{% block footer %}&copy; {{ site.year }} {{ site.name|escape }} - prices in {{ site.currency|lower }}{% endblock %}</footer>\n'
        '</body></html>'
    )
    nav = (
        '<nav>{% for cat in categories %}<a href="#{{ cat.slug }}"{% if cat.slug == (categories|first).slug %} class="first"{% endif %}>'
        '{{ cat.name }}</a>{% if cat.slug != (categories|last).slug %} | {% endif %}{% endfor %}</nav>\n'
        '<p>Featured: {{ featured|sort|join(", ") }}</p>'
    )
    card = (
        '<article class="product{% if p.badge is defined %} badge-{{ p.badge }}{% endif %}" data-id="{{ p.id }}" '
        'data-sku="{{ p.sku|lower|replace("-", "_") }}">\n'
        '    <h3>{{ p.name|trim|upper }} <small>by {{ p.brand }}</small></h3>\n'
        '    <p class="desc">{{ p.description|trim|escape }}</p>\n'
        '    {%- if p.discount %}\n'
        '    <p class="price"><s>{{ money(p.price) }}</s> {{ money((p.price * (1 - p.discount))|int) }}'
        ' (save {{ (p.discount * 100)|int }}%)</p>\n'
        '    {%- else %}\n'
        '    <p class="price">{{ money(p.price) }}</p>\n'
        '    {%- endif %}\n'
        '    <p class="rating">{{ stars(p.rating) }} {{ p.rating }} / 5 from {{ p.reviews }} review{% if p.reviews != 1 %}s{% endif %}'
        '{% if p.reviews > 1000 and p.rating >= 4.5 %} - top rated{% endif %}</p>\n'
        '    {%- if p.tags %}\n'
        '    <p class="tags">{{ p.tags|sort|join(" #")|default("") }} ({{ p.tags|length }})</p>\n'
        '    {%- endif %}\n'
        '    <ul class="variants">\n'
        '    {%- for v in p.variants %}\n'
        '      <li>{{ v.size }}/{{ v.color|upper }}: '
        '{% if v.stock == 0 %}sold out{% elif v.stock < 5 %}only {{ v.stock }} left{% else %}in stock{% endif %}'
        '{% if v == p.variants|last %} ({{ p.variants|length }} option{% if p.variants|length > 1 %}s{% endif %}){% endif %}</li>\n'
        '    {%- endfor %}\n'
        '    </ul>\n'
        '    <dl>{% for k in p.attrs %}<dt>{{ k|replace("_", " ") }}</dt><dd>{{ p.attrs[k] }}</dd>{% endfor %}</dl>\n'
        '    {%- if p.id in featured %} <em>featured</em>{% endif %}\n'
        '    <span class="pos">{{ loop.index }}/{{ loop.length }}</span>\n'
        '  </article>'
    )
    # Included templates never refer to `loop` (SPEC guarantee 7): the card's
    # position comes from a loop-local set made before the include.
    card = card.replace('{{ loop.index }}/{{ loop.length }}', '{{ pos }}/{{ cat.products|length }}')
    page = page.replace('  {% include "card" %}', '  {% set pos = loop.index %}{% include "card" %}')
    return make_input(context, [('catalog', page), ('layout', layout), ('nav', nav), ('card', card)])


# ---------------------------------------------------------------------------
# 002: recursive macros over trees (the algorithmically hardest part)
# ---------------------------------------------------------------------------
def make_tree(rng, depth, width, counter):
    counter[0] += 1
    node = {'id': counter[0], 'name': rng.choice(WORDS) + str(rng.randint(0, 99)),
            'size': rng.randint(0, 9000), 'children': []}
    if depth > 0:
        for _ in range(rng.randint(1, width)):
            node['children'].append(make_tree(rng, depth - 1, width, counter))
    return node


def macro_trees(trees=None):
    """A directory-tree report: recursive render with per-node subtree aggregates."""
    rng = random.Random(9002)
    forest = []
    for _ in range(trees or TREES):
        counter = [0]
        forest.append(make_tree(rng, 8, 4, counter))
    context = {'forest': forest, 'unit': 'KB'}
    main = (
        '{% macro total(n) %}{{ n.size + total_rest(n.children, 0)|int }}{% endmacro %}'
        '{% macro total_rest(xs, i) %}{% if i < xs|length %}{{ total(xs[i])|int + total_rest(xs, i + 1)|int }}{% else %}0{% endif %}{% endmacro %}'
        '{% macro count(n) %}{{ 1 + count_rest(n.children, 0)|int }}{% endmacro %}'
        '{% macro count_rest(xs, i) %}{% if i < xs|length %}{{ count(xs[i])|int + count_rest(xs, i + 1)|int }}{% else %}0{% endif %}{% endmacro %}'
        '{% macro height(n) %}{% if n.children %}{{ 1 + hmax(n.children, 0)|int }}{% else %}0{% endif %}{% endmacro %}'
        '{% macro hmax(xs, i) %}{% if i < xs|length %}{% set a = height(xs[i])|int %}{% set b = hmax(xs, i + 1)|int %}'
        '{% if a > b %}{{ a }}{% else %}{{ b }}{% endif %}{% else %}0{% endif %}{% endmacro %}'
        '{% macro render(n, depth, path) %}{% set t = total(n)|int %}{% set c = count(n)|int %}'
        '{{ "  " * depth }}{{ path ~ "/" ~ n.name }} [{{ n.id }}] {{ n.size }}{{ unit }}'
        '{% if n.children %} subtree={{ t }}{{ unit }} files={{ c }} avg={{ t / c }}'
        ' h={{ height(n) }}{% endif %}\n'
        '{% for ch in n.children %}{{ render(ch, depth + 1, path ~ "/" ~ n.name) }}{% endfor %}{% endmacro %}'
        '{% for tree in forest %}== tree {{ loop.index }} of {{ loop.length }} ==\n'
        '{{ render(tree, 0, "") }}'
        'summary: nodes={{ count(tree) }} bytes={{ total(tree) }} height={{ height(tree) }}\n'
        '{% endfor %}'
    )
    return make_input(context, [('report', main)])


# ---------------------------------------------------------------------------
# 003: mixed analytics dashboard (big template + inheritance + floats)
# ---------------------------------------------------------------------------
EXTRA_REGIONS = ['alpine', 'bay', 'canyon', 'desert', 'forest', 'gulf', 'harbor', 'island',
                 'lakes', 'midland', 'northeast', 'northwest', 'plains', 'prairie', 'river',
                 'southeast', 'southwest', 'valley']


def dashboard(n_products=320, n_regions=8):
    """A generated sales dashboard: big multi-level template, nested loops, float math."""
    rng = random.Random(9003)
    regions = ['north', 'south', 'east', 'west', 'central', 'coastal', 'highland', 'metro']
    regions += EXTRA_REGIONS[:n_regions - len(regions)]
    months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec']
    products = ['%s_%d' % (rng.choice(WORDS), i) for i in range(n_products)]
    sales = {}
    for r in regions:
        sales[r] = {}
        for p in products:
            sales[r][p] = [rng.randint(0, 900) for _ in months]
    prices = {p: round(rng.uniform(0.5, 250.0), 2) for p in products}
    targets = {r: rng.randint(150000, 400000) for r in regions}
    context = {'regions': regions, 'months': months, 'products': products, 'sales': sales,
               'prices': prices, 'targets': targets, 'company': 'Northwind', 'tax': 0.0825}

    base = (
        '{% macro pct(a, b) %}{% if b %}{{ (a * 1000 // b) / 10 }}%{% else %}n/a{% endif %}{% endmacro %}'
        '{% macro bar(v, scale) %}{{ "#" * (v // scale) }}{% endmacro %}'
        '# {% block heading %}{{ company }} dashboard{% endblock %}\n'
        '{% block summary %}(no summary){% endblock %}\n'
        '{% block regions %}{% endblock %}\n'
        '{% block products %}{% endblock %}\n'
        '{% block sections %}{% endblock %}\n'
        '{% block monthly %}{% endblock %}\n'
        '{% block versus %}{% endblock %}\n'
        '-- end of {% block footer %}report{% endblock %} --'
    )
    mid = (
        '{% extends "base" %}'
        '{% block heading %}{{ super() }} / annual{% endblock %}'
        '{% block summary %}'
        '{% for r in regions %}{% for p in products %}{% for v in sales[r][p] %}'
        '{% if v > 880 %}{{ r }}:{{ p }}:{{ months[loop.index0] }}={{ v }} {% endif %}'
        '{% endfor %}{% endfor %}{% endfor %}\n'
        '{% endblock %}'
        '{% block regions %}'
        '{% for r in regions %}'
        '## {{ r|upper }} (target {{ targets[r] }})\n'
        '{% for m in months %}{% set mi = loop.index0 %}'
        '{{ m }}: {% for p in products %}{% if sales[r][p][mi] > 450 %}{{ p|replace("_", "-") }} {% endif %}{% endfor %}\n'
        '{% endfor %}'
        '{% endfor %}'
        '{% endblock %}'
        '{% block monthly %}'
        '{% for m in months %}{% set mi = loop.index0 %}{{ m|upper }}:'
        '{% for p in products %}{% set tot = sales.north[p][mi] + sales.south[p][mi] + sales.east[p][mi] + sales.west[p][mi] + sales.central[p][mi] + sales.coastal[p][mi] + sales.highland[p][mi] + sales.metro[p][mi] %}'
        ' {{ tot / 8 }}{% if tot > 4800 %}!{% elif tot < 2400 %}?{% endif %}{% endfor %}\n'
        '{% endfor %}'
        '{% endblock %}'
        '{% block versus %}'
        '{% for a in regions %}{% for b in regions %}{% if a != b %}{{ a }}-{{ b }} '
        '{% for p in products %}{% if sales[a][p]|sort|last > sales[b][p]|sort|last %}W{% elif sales[a][p][0] == sales[b][p][0] %}D{% else %}L{% endif %}{% endfor %}\n'
        '{% endif %}{% endfor %}{% endfor %}'
        '{% endblock %}'
        '{% block footer %}{{ super() }} ({{ regions|length }} regions){% endblock %}'
    )
    # The leaf template is large: one or two generated sections per product
    # and region pair, so lexing and parsing a ~1 MB template matters too.
    leaf = ['{% extends "mid" %}\n', '{% set threshold = 300 %}\n']
    leaf.append('{% block heading %}{{ super() }} [FY{{ 2026 }}]{% endblock %}\n')
    leaf.append('{% block products %}\n'
                '{% for p in products %}'
                '{{ loop.index }}. {{ p }} @ {{ prices[p] }}: '
                '{% for r in regions %}{{ r[0]|upper }}{{ sales[r][p]|sort|last }}{% if not loop.last %},{% endif %}{% endfor %} '
                'gross {{ (prices[p] * (sales.north[p][0] + sales.south[p][0] + sales.east[p][0])) // 1 }} '
                'net {{ prices[p] * (1 - tax) }}\n'
                '{% endfor %}'
                '{% endblock %}\n')
    leaf.append('{% block sections %}\n')
    sec = 0
    pairs = [(p, r) for p in products[:200] for r in regions[:8]]
    pairs += rng.sample(pairs, len(pairs) // 2)
    for p, r in pairs:
        sec += 1
        k = rng.random()
        m = rng.randrange(12)
        if k < 0.35:
            leaf.append(
                '### {{ "%s"|upper }} / %s\n'
                '{%% for v in sales.%s.%s %%}{%% if v > threshold %%}{{ months[loop.index0] }} {{ v }} '
                '{{ bar(v, 60) }} {{ pct(v, %d) }}\n{%% endif %%}{%% endfor %%}'
                'max={{ sales.%s.%s|sort|last }} min={{ sales.%s.%s|sort|first }} '
                'mean={{ (sales.%s.%s|join("+")|length) / 12 }}\n'
                % (r, p, r, p, rng.randint(400, 900), r, p, r, p, r, p))
        elif k < 0.65:
            leaf.append(
                '{{ "%s" ~ ":" ~ "%s" }} q1={{ sales.%s.%s[0] + sales.%s.%s[1] + sales.%s.%s[2] }} '
                'rev={{ prices.%s * sales.%s.%s[%d] }} share={{ pct(sales.%s.%s[%d], targets.%s // 100) }} '
                '{%% if sales.%s.%s[%d] > sales.%s.%s[%d] %%}up{%% elif sales.%s.%s[%d] == sales.%s.%s[%d] %%}flat{%% else %%}down{%% endif %%}\n'
                % (r, p, r, p, r, p, r, p, p, r, p, m, r, p, m, r, r, p, m, r, p, (m + 11) % 12,
                   r, p, m, r, p, (m + 11) % 12))
        elif k < 0.85:
            leaf.append(
                '{%% for q in range(4) %%}{%% set lo = q * 3 %%}Q{{ q + 1 }}={{ sales.%s.%s[lo] + sales.%s.%s[lo + 1] + sales.%s.%s[lo + 2] }}'
                '{%% if not loop.last %%} {%% endif %%}{%% endfor %%} '
                '{# section %d: %s in %s #}'
                'ratio={{ sales.%s.%s[%d] / (sales.%s.%s[%d] + 1) }}\n'
                % (r, p, r, p, r, p, sec, p, r, r, p, m, r, p, (m + 5) % 12))
        else:
            leaf.append(
                '{%% if "%s" in sales.%s and %d in sales.%s.%s %%}hit{%% else %%}miss{%% endif %%} '
                '{{ [sales.%s.%s[%d], prices.%s, "%s"] }} {{ (sales.%s.%s|sort|reverse|first) ** 2 }}\n'
                % (p, r, rng.randint(0, 900), r, p, r, p, m, p, r, r, p))
    leaf.append('{% endblock %}\n')
    leaf.append('{%% block footer %%}{{ super() }}; generated sections {{ %d }}{%% endblock %%}' % sec)
    return make_input(context, [('dashboard', ''.join(leaf)), ('mid', mid), ('base', base)])


TREES = 7

ORACLE_CODE = None


def oracle_python():
    try:
        import jinja2  # noqa: F401
        return sys.executable
    except ImportError:
        pass
    for p in (ORACLE_PY, REPO_ORACLE_PY):
        if os.path.exists(p):
            return p
    return None


def load_oracle_code():
    sys.path.insert(0, PROBLEM)
    sys.dont_write_bytecode = True
    import io
    import contextlib
    with contextlib.redirect_stdout(io.StringIO()):
        import gen_tests  # noqa: E402  (module level only builds the case list)
    return gen_tests.ORACLE_CODE


def run(cmd, data):
    proc = subprocess.run(cmd, input=data.encode('utf-8'), capture_output=True, timeout=2700)
    if proc.returncode != 0:
        sys.exit('command failed: %s\n%s' % (cmd, proc.stderr.decode('utf-8', 'replace')[-2000:]))
    return proc.stdout.decode('utf-8')


def normalize(text):
    return '\n'.join(line.rstrip() for line in text.split('\n')).rstrip('\n')


# Long tier (--long, written to ../bench-long): the same three pages over a
# bigger catalogue with many more featured lookups, more trees, and more
# products in the dashboard.
LONG_CATALOG = dict(per_cat=(720, 1020), n_featured=5000)
LONG_TREES = 190
LONG_DASHBOARD = dict(n_products=10000, n_regions=24)


def main():
    long_tier = '--long' in sys.argv[1:]
    out_dir = os.path.join(PROBLEM, 'bench-long') if long_tier else HERE
    os.makedirs(out_dir, exist_ok=True)
    if long_tier:
        cases = [('001_catalog_page', catalog_page(**LONG_CATALOG)),
                 ('002_macro_tree_report', macro_trees(LONG_TREES)),
                 ('003_dashboard_mixed', dashboard(**LONG_DASHBOARD))]
    else:
        cases = [('001_catalog_page', catalog_page()),
                 ('002_macro_tree_report', macro_trees()),
                 ('003_dashboard_mixed', dashboard())]
    if '--inputs-only' in sys.argv[1:]:
        for name, data in cases:
            with open(os.path.join(out_dir, name + '.in'), 'w', encoding='utf-8') as f:
                f.write(data)
        return
    only = [a for a in sys.argv[1:] if not a.startswith('--')]
    if only:
        cases = [c for c in cases if any(o in c[0] for o in only)]
    opy = oracle_python()
    code = load_oracle_code() if opy else None
    for name, data in cases:
        expected = run([sys.executable, REF], data)
        assert not expected.startswith('error: '), name + ' ' + expected[:100]
        if opy:
            oracle_out = run([opy, '-c', code], data)
            if normalize(expected) != normalize(oracle_out):
                sys.exit('ORACLE DISAGREES on %s' % name)
        with open(os.path.join(out_dir, name + '.in'), 'w', encoding='utf-8') as f:
            f.write(data)
        with open(os.path.join(out_dir, name + '.out'), 'w', encoding='utf-8') as f:
            f.write(expected)
        print('%-28s in %8d bytes  out %8d bytes  %s' % (
            name, len(data.encode()), len(expected.encode()), 'jinja2-checked' if opy else 'unchecked'))


if __name__ == '__main__':
    main()
