#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `template` problem.

Every test is an embedded literal or the product of a seeded generator, so
re-running this script reproduces the suite exactly. Expected outputs come
from reference/main.py and every one of them is cross-checked against
Jinja2 (the oracle: StrictUndefined, trim_blocks/lstrip_blocks off,
keep_trailing_newline on, DictLoader of the named templates); the script
aborts on any disagreement. Jinja2 is imported from the repository's
oracle virtualenv when it is not importable by the running interpreter.
"""
import json
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')
ORACLE_PY = os.path.join(HERE, '..', '..', '.oracle-venv', 'bin', 'python')

cases = []


def add(name, context, templates, compact=False):
    """Registers a test: `templates` is a list of (name, body); the first is rendered."""
    if isinstance(context, str):
        ctx_text = context
    else:
        ctx_text = json.dumps(context, ensure_ascii=False, separators=(',', ':')) if compact \
            else json.dumps(context, ensure_ascii=False, indent=2)
    parts = [ctx_text, '\n--\n']
    for tname, body in templates:
        assert not any(line.startswith('===') for line in body.split('\n')), name
        parts.append('=== ' + tname + '\n' + body + '\n')
    cases.append((name, ''.join(parts)))


def T(body, **others):
    """Shorthand: main template plus optional extra templates by keyword."""
    return [('main', body)] + list(others.items())


# ---------------------------------------------------------------------------
# Hand-written cases: basics
# ---------------------------------------------------------------------------
add('empty_template', {}, T(''))
add('plain_text', {}, T('Just text.\nWith { braces } and } and { and a % sign and # too.\n\n  indented\n'))
add('variable', {'name': 'World'}, T('Hello {{ name }}!'))
add('literals_and_arithmetic', {}, T(
    '{{ 1 + 2 }} {{ 10 - 3 * 2 }} {{ (10 - 3) * 2 }} {{ 7 / 2 }} {{ 6 / 3 }} {{ 7 // 2 }} {{ -7 // 2 }} '
    '{{ 7 % 3 }} {{ -7 % 3 }} {{ 7 % -3 }} {{ 2 ** 10 }} {{ 2 ** 3 ** 2 }} {{ -2 ** 2 }} '
    '{{ 1.5 + 1.5 }} {{ 2 * 1.5 }} {{ 7.0 // 2 }} {{ 7.5 % 2 }} {{ 0.1 + 0.2 }} {{ 1 / 3 }}\n'
    '{{ "abc" }} {{ \'def\' }} {{ "a\\"b" }} {{ \'c\\\'d\' }} {{ "tab\\there" }} {{ "back\\\\slash" }} '
    '{{ "new\\nline" }} {{ "it\'s" }} {{ \'say "hi"\' }}\n'
    '{{ true }} {{ false }} {{ none }} {{ 42 }} {{ -42 }} {{ 3.25 }} {{ 100 }}\n'
    '{{ "ab" ~ "cd" }} {{ "n=" ~ 5 }} {{ 1 ~ 2 }} {{ "x" ~ 1.5 ~ true ~ none }} {{ "ab" * 3 }} {{ 2 * "ab" }} {{ "ab" * 0 }}\n'
    '{{ "a" ~ 2 * 3 }} {{ [1, 2] + [3] }} {{ "abc" + "def" }} {{ (1 + 2) ~ 3 }}'))
add('attribute_access', {'user': {'name': 'Ada', 'langs': ['py', 'c', 'd'], 'meta': {'age': 36, 'tags': []}},
                         'list': [10, 20, 30], 'key': 'name', 'idx': 2, 's': 'hello'},
    T('{{ user.name }} {{ user["name"] }} {{ user[key] }} {{ user.langs[0] }} {{ user.langs[-1] }} '
      '{{ user["langs"][1] }} {{ user.meta.age }} {{ user["meta"]["age"] + 1 }} {{ user.meta.tags }}\n'
      '{{ list[0] }} {{ list[idx] }} {{ list[-3] }} {{ list[idx - 1] }} {{ list[1 + 1] }} {{ s[0] }} {{ s[-1] }} {{ s[1] ~ s[2] }}\n'
      '{{ "literal"[2] }} {{ [4, 5, 6][1] }} {{ ([7, 8] + [9])[2] }} {{ user.langs[user.meta.age - 34] }} {{ list[true] }}'))
add('comparison_and_logic', {'a': 3, 'b': 5, 's': 'abc', 'l': [1, 2, 3], 'd': {'k': 1}, 'f': 2.0},
    T('{{ a < b }} {{ a <= 3 }} {{ a > b }} {{ a >= b }} {{ a == 3 }} {{ a != 3 }} {{ a == f - 0.0 + 1 }} {{ 1 == 1.0 }} {{ "a" < "b" }} {{ "ab" < "b" }} {{ "B" < "a" }}\n'
      '{{ 1 < a < b }} {{ 1 < b < a }} {{ a == 3 == true }} {{ 1 == "1" }} {{ none == none }} {{ none == 0 }} {{ [1, 2] == [1, 2] }} {{ [1, 2] == [1, 3] }} {{ d == d }} {{ "" == none }}\n'
      '{{ a and b }} {{ 0 and b }} {{ a or b }} {{ 0 or b }} {{ "" or "x" }} {{ none or false }} {{ not a }} {{ not 0 }} {{ not none }} {{ not "" }} {{ not [] }} {{ not [0] }}\n'
      '{{ 1 in l }} {{ 4 in l }} {{ 4 not in l }} {{ "b" in s }} {{ "bc" in s }} {{ "" in s }} {{ "x" not in s }} {{ "k" in d }} {{ "z" in d }} {{ 1 in d }}\n'
      '{{ not a == 4 }} {{ not a and b }} {{ a > 1 and b > 1 or false }} {{ false or false and true }} {{ not not a }} {{ true == 1 }} {{ true + 1 }} {{ true < 2 }} {{ -true }}'))
add('if_elif_else', {'a': 0, 'b': '', 'c': [0], 'n': 7},
    T('{% if a %}A{% elif b %}B{% elif c %}C{% else %}D{% endif %}\n'
      '{% if n > 10 %}big{% elif n > 5 %}medium{% else %}small{% endif %}\n'
      '{% if a %}yes{% endif %}[{% if not a %}no{% endif %}]\n'
      '{% if n == 7 %}{% if n > 3 %}nested{% else %}inner-else{% endif %}{% else %}outer-else{% endif %}\n'
      '{% if a %}1{% elif a %}2{% elif a %}3{% endif %}|{% if [] %}x{% else %}empty-list-is-false{% endif %}'))
add('for_loop', {'items': ['a', 'b', 'c'], 'nums': [10, 20, 30, 40]},
    T('{% for x in items %}{{ loop.index }}:{{ x }} {% endfor %}\n'
      '{% for n in nums %}[{{ loop.index0 }}/{{ loop.length }} {{ n }} first={{ loop.first }} last={{ loop.last }}]{% endfor %}\n'
      '{% for n in nums %}{{ n }}{% if not loop.last %}, {% endif %}{% endfor %}\n'
      '{% for c in "xyz" %}{{ c }}-{% endfor %}{% for i in [1, [2, 3], "s"] %}<{{ i }}>{% endfor %}'))
add('for_else', {'empty': [], 'full': [1], 'd': {}},
    T('{% for x in empty %}never{% else %}EMPTY{% endfor %}|{% for x in full %}{{ x }}{% else %}nope{% endfor %}|'
      '{% for k in d %}k{% else %}no keys{% endfor %}|{% for x in "" %}c{% else %}no chars{% endfor %}|'
      '{% for x in empty %}x{% endfor %}[end]'))
add('nested_loops', {'rows': [[1, 2, 3], [4, 5], []], 'names': ['x', 'y']},
    T('{% for row in rows %}row {{ loop.index }} (len {{ loop.length }}):{% for v in row %} {{ loop.index }}={{ v }}{% if loop.last %}.{% endif %}{% else %} empty{% endfor %} back to {{ loop.index }}\n{% endfor %}'
      '{% for a in names %}{% for b in names %}{% if a != b %}{{ a }}{{ b }} {% endif %}{% endfor %}{% endfor %}\n'
      '{% for i in range(3) %}{% for j in range(i) %}{{ i }}{{ j }}{% endfor %}|{% endfor %}'))
add('set_and_scoping', {'items': [1, 2, 3], 'base': 10},
    T('{% set total = 0 %}{% set label = "sum" %}'
      '{% for i in items %}{% set total = total + i %}{{ label }}[{{ loop.index }}]={{ total }} {% endfor %}after={{ total }}\n'
      '{% set x = 1 %}{{ x }}{% set x = x + 1 %}{{ x }}{% set x = x * base %}{{ x }} {% if x > 10 %}{% set y = "big" %}{% else %}{% set y = "small" %}{% endif %}{{ y }}\n'
      '{% for i in items %}{% set sq = i * i %}{{ sq }}{% endfor %} {{ sq is defined }} {{ i is defined }} {{ loop is defined }}\n'
      '{% set l = [base, base * 2, "s"] %}{{ l }} {{ l|length }} {% set n = none %}{{ n }} {% set b = base > 5 %}{{ b }}'))
add('filters_basic', {'s': '  Hello, World!  ', 'l': [3, 1, 2], 'w': 'mixed CASE', 'e': [], 'd': {'b': 1, 'a': 2}},
    T('[{{ s|trim }}] [{{ s|upper }}] [{{ w|lower }}] {{ s|length }} {{ s|trim|length }} {{ l|length }} {{ d|length }} {{ ""|length }}\n'
      '{{ l|reverse|join(",") }} {{ "abc"|reverse }} {{ l|first }} {{ l|last }} {{ "abc"|first }} {{ "abc"|last }} {{ d|first }} {{ d|last }} {{ d|reverse|join(",") }}\n'
      '{{ e|first is defined }} {{ e|last is defined }} {{ ""|first is defined }} {{ 5|upper }} {{ none|lower }} {{ true|upper }} {{ 1.5|trim }} {{ "héllo wörld"|length }}'))
add('filters_with_args', {'l': [1, 'two', 3.5, True, None], 'nested': [[1, 2], [3]], 'html': '<a href="x">Tom & Jerry\'s</a>'},
    T('{{ l|join(", ") }}|{{ l|join }}|{{ nested|join(";") }}|{{ "abc"|join("-") }}|{{ [1, 2]|join(0) }}\n'
      '{{ missing|default("dflt") }}|{{ missing|default(5) + 1 }}|{{ l[0]|default("no") }}|{{ l[9]|default("oor") }}|[{{ missing|default }}]|{{ none|default("n") }}|{{ 0|default(1) }}\n'
      '{{ "aaa"|replace("a", "b") }} {{ "abcabc"|replace("bc", "X") }} {{ "aXbXc"|replace("X", "") }} {{ "a1b"|replace(1, 2) }} {{ 121|replace("1", "x") }} {{ "no match"|replace("z", "y") }}\n'
      '{{ "42"|int }} {{ " 7 "|int }} {{ "-3"|int }} {{ "+4"|int }} {{ "3.9"|int }} {{ "-3.9"|int }} {{ "abc"|int }} {{ ""|int }} {{ "1e2"|int }} {{ ".5"|int }} {{ "5."|int }} {{ 3.9|int }} {{ -3.9|int }} {{ true|int }} {{ 12|int }} {{ none|int }} {{ "12abc"|int }}\n'
      '{{ html|escape }} {{ 5|escape }} {{ "plain"|escape }}'))
add('filters_chained', {'words': ['banana', 'Apple', 'cherry'], 's': '  Mixed Case  '},
    T('{{ s|trim|lower|replace("case", "text")|upper }} {{ s|trim|length }} {{ words|join(" ")|upper|replace("A", "4") }}\n'
      '{{ words|sort|first|upper }} {{ words|sort|last }} {{ words|reverse|join("+") }} {{ words|first|reverse|upper }} {{ words|join|length }}\n'
      '{{ "3"|int + "4"|int }} {{ ("3" ~ "4")|int * 2 }} {{ [1, 2, 3]|reverse|first + [1, 2, 3]|last }} {{ (words|sort)[1] }} {{ words|sort|join(",")|length }}'))
add('sort_filter', {'words': ['banana', 'Apple', 'cherry', 'apple', 'Banana', 'b', 'B', 'a'], 'nums': [3, 1.5, 2, -1, 0, 2.5, 10], 'd': {'z': 1, 'a': 2, 'M': 3}},
    T('{{ words|sort|join(",") }}\n{{ nums|sort|join(",") }}\n{{ d|sort|join(",") }}\n{{ "hello"|sort|join }}\n'
      '{{ []|sort }} {{ [true, false, 0, 1]|sort|join(",") }} {{ ["b", "a"]|sort }}'))
add('macros_basic', {'greeting': 'Hi'},
    T('{% macro hello(name, punct="!") %}{{ greeting }}, {{ name }}{{ punct }}{% endmacro %}'
      '{% macro box(content, width=3, pad="*") %}{{ pad * width }}{{ content }}{{ pad * width }}{% endmacro %}'
      '{% macro args(a, b, c) %}a={{ a }} b={{ b|default("-") }} c={{ c is defined }}{% endmacro %}'
      '{% macro defaults(a, b=a, c=b ~ "!") %}{{ a }}{{ b }}{{ c }}{% endmacro %}'
      '{{ hello("Ada") }} {{ hello("Bob", "?") }} {{ hello(name="Cy", punct=".") }} {{ hello(punct=";", name="Di") }}\n'
      '{{ box("x") }} {{ box("y", 1) }} {{ box("z", pad="-") }} {{ box(width=2, content="w") }}\n'
      '{{ args(1) }} | {{ args(1, 2) }} | {{ args(1, 2, 3) }} | {{ args(1, c=3) }}\n'
      '{{ defaults(1) }} {{ defaults(1, 2) }} {{ defaults(1, 2, 3) }} {{ defaults("x", c="y") }}\n'
      '{% macro late() %}{{ mood }}{% endmacro %}{% set mood = "Yo" %}{{ late() }} {% set r = hello("stored") %}{{ r|upper }} {{ r|length }}'))
add('macro_recursion', {'tree': {'name': 'root', 'kids': [{'name': 'a', 'kids': [{'name': 'a1', 'kids': []}, {'name': 'a2', 'kids': []}]}, {'name': 'b', 'kids': []}]}},
    T('{% macro fact(n) %}{% if n <= 1 %}1{% else %}{{ n * fact(n - 1)|int }}{% endif %}{% endmacro %}'
      '{% macro fib(n) %}{% if n < 2 %}{{ n }}{% else %}{{ fib(n - 1)|int + fib(n - 2)|int }}{% endif %}{% endmacro %}'
      '{% macro render(node, depth=0) %}{{ "  " * depth }}- {{ node.name }}\n{% for k in node.kids %}{{ render(k, depth + 1) }}{% endfor %}{% endmacro %}'
      '{% macro even(n) %}{% if n == 0 %}true{% else %}{{ odd(n - 1) }}{% endif %}{% endmacro %}'
      '{% macro odd(n) %}{% if n == 0 %}false{% else %}{{ even(n - 1) }}{% endif %}{% endmacro %}'
      '{{ fact(10) }} {{ fib(15) }} {{ even(10) }} {{ odd(7) }}\n{{ render(tree) }}'))
add('macro_scoping', {'v': 'ctx', 'items': [1, 2]},
    T('{% macro show() %}[{{ v }} {{ w }} {{ i is defined }} {{ loop is defined }}]{% endmacro %}'
      '{% set w = "top" %}{{ show() }}{% for i in items %}{{ show() }}{% endfor %}\n'
      '{% macro inner() %}{% set local = "local" %}{{ local }}{% endmacro %}{{ inner() }} {{ w }} {{ local is defined }}\n'
      '{% macro outer(x) %}{% macro nested(y) %}{{ x }}{{ y }}{% endmacro %}{{ nested(1) }}{{ nested(2) }}{% endmacro %}{{ outer("o") }} {{ nested is defined }}\n'
      '{% macro shadow(v) %}{{ v }}{% endmacro %}{{ shadow("param") }} {{ v }} {{ shadow is defined }} {{ show is defined }}'))
add('include_basic', {'name': 'Ada', 'items': ['x', 'y']},
    T('Start\n{% include "header" %}\n{% for it in items %}{% include "item" %}{% endfor %}\n{% set local = "L" %}{% include "footer" %}{{ inner is defined }}|{{ local }}',
      header='== {{ name|upper }} ==', item='<{{ it }}{{ loop_free|default("") }}>', footer='{% set inner = 1 %}{{ local }}{{ inner }} {{ name }}'))
add('include_nested_and_dynamic', {'which': 'b', 'depth': 3},
    T('{% include "a" %}|{% include which %}|{% include "r1" %}|{% for k in ["c", "b"] %}{% include k %}{% endfor %}', a='A{% include "b" %}', b='B{% include "c" %}', c='C',
      r1='{% if depth > 0 %}{{ depth }}{% set depth1 = depth - 1 %}{% include "r2" %}{% else %}.{% endif %}',
      r2='{% if depth1 > 0 %}{{ depth1 }}{% set depth2 = depth1 - 1 %}{% include "r3" %}{% else %}.{% endif %}',
      r3='{{ depth2 }} {{ depth1 }} {{ depth }} {{ which }}'))
add('extends_basic', {'title': 'Home'},
    T('{% extends "base" %}\n{% block title %}{{ title }} page{% endblock %}\n{% block content %}Welcome to {{ title }}.{% endblock %}\n',
      base='<html><head><title>{% block title %}Default{% endblock %}</title></head>\n<body>{% block content %}{% endblock %}\n<footer>{% block footer %}(c) {{ title }}{% endblock %}</footer></body></html>'))
add('extends_super_and_nesting', {'items': [1, 2]},
    T('{% extends "base" %}{% block outer %}C-outer[{{ super() }}]{% endblock %}{% block inner %}C-inner({{ super() }}){% endblock %}{% block deep %}C-deep{% endblock %}',
      base='<{% block outer %}B-outer{{ "{" }}{% block inner %}B-inner<{% block deep %}B-deep{% endblock %}>{% endblock %}{{ "}" }}{% endblock %}>\n'
           '{% block alone %}only in base{% endblock %} {% for i in items %}{{ i }}{% endfor %}'))
add('extends_three_levels', {'x': 'X'},
    T('{% extends "mid" %}{% block a %}A3({{ super() }}){% endblock %}{% block c %}C3{% endblock %}',
      mid='{% extends "base" %}{% block a %}A2({{ super() }}){% endblock %}{% block b %}B2({{ super() }}){% endblock %}{% block d %}D2{% endblock %}',
      base='[{% block a %}A1{% endblock %}|{% block b %}B1{% endblock %}|{% block c %}C1{% endblock %}|{% block d %}D1{% endblock %}|{% block e %}E1{{ x }}{% endblock %}]'))
add('extends_scope_and_text_before', {'title': 'T'},
    T('Prelude {{ title }}\n{% set child_var = "cv" %}{% macro cm() %}child-macro{% endmacro %}{% extends "base" %}\n'
      '{% set after = "set-after-extends" %}{% macro am() %}macro-after{% endmacro %}\n'
      '{% block body %}{{ child_var }} {{ after }} {{ cm() }} {{ am() }} {{ pm() }} {{ parent_var }} {{ later is defined }}{% set inblock = 1 %}{% endblock %}\nignored text\n',
      base='{% set parent_var = "pv" %}{% macro pm() %}parent-macro{% endmacro %}<{% block body %}{% endblock %}>{% set later = 1 %}{{ inblock is defined }}'))
add('extends_blocks_scoping', {'items': ['a', 'b'], 'cv': 'ctx'},
    T('{% extends "base" %}{% block item %}{{ v }}{{ i is defined }}{{ super() }}{% endblock %}{% block note %}{% set v2 = "block-local" %}{{ v2 }}{% block subnote %}{{ v2 is defined }}{% endblock %}{% endblock %}',
      base='{% block note %}{% endblock %}|{% set v = "top" ~ cv %}{% block item %}{{ v }}{% endblock %}|{% block subnote %}base-sub{% endblock %}|{{ v2 is defined }}'))
add('include_inside_blocks_and_extends_in_include', {'name': 'N'},
    T('{% extends "base" %}{% block body %}{% include "part" %}|{% include "child" %}{% endblock %}',
      base='[{% block body %}{% endblock %}]', part='part({{ name }})',
      child='{% extends "base2" %}{% block inner %}inner-of-child {{ name }}{% endblock %}', base2='{{ "{" }}{% block inner %}{% endblock %}{{ "}" }}'))
add('whitespace_control', {'items': [1, 2, 3], 'flag': True},
    T('A\n  {%- if flag %}\n  yes\n  {%- endif %}\nB\n'
      '{% for i in items -%}\n  {{ i }}\n{%- endfor %}\nC\n'
      '{% for i in items %}\n  {{- i }}\n{% endfor %}\nD\n'
      '  {%- set x = 1 -%}  \n  E{{ x }}\n'
      'F {{- " tight " -}} G\nH\t\n\t{{- "I" }}\n\n\n{%- if true -%}\n\n\nJ\n\n{%- endif -%}\n\nK\n'
      '{% if flag -%}   L   {%- endif %}\n{%- if flag %}M{% endif -%}\n\n  N\n{# comment #}\nO\n  {#- stripped -#}  \nP\n'
      '{{ "Q" -}}\n\n\n{{- "R" }}  \n  {%- for i in [1] -%}  S  {%- endfor -%}  T\nEND'))
add('comments', {'x': 1},
    T('a{# simple #}b\n{# multi\nline\n comment #}c\n{#{{ x }} {% if %} not parsed #}d\n{# # } #}e{##}f\n'
      'g  {#- strip before #}  h\ni  {# strip after -#}  j\nk  {#- both -#}  l\n{#-#}m{#--#}  n\n{{ x }}{# after tag #}{{ x }}'))
add('undefined_handling', {'d': {'k': 'v', 'n': None, 'z': 0, 'l': []}, 'lst': [1]},
    T('{{ missing is defined }} {{ missing is not defined }} {{ d is defined }} {{ d.k is defined }} {{ d.x is defined }} {{ d["x"] is not defined }} '
      '{{ d.n is defined }} {{ d.z is defined }} {{ lst[0] is defined }} {{ lst[1] is defined }} {{ lst[-2] is defined }} {{ lst.x is defined }} {{ "s".x is defined }} {{ d.n.x is defined }} {{ (5).x is defined }}\n'
      '{{ missing|default("m") }} {{ d.x|default("dx") }} {{ d.n|default("not replaced") }} {{ d.z|default(9) }} {{ lst[5]|default(lst[0]) }} {{ d.l|first|default("empty") }}\n'
      '{% set u = missing %}{{ u is defined }} {% set v = d.x %}{{ v is defined }} {{ v|default("V") }} '
      '{% if missing is defined %}yes{% else %}no{% endif %} {% if d.k is defined and d.k == "v" %}ok{% endif %} '
      '{% if missing is not defined or missing %}short{% endif %} {{ 1 > 2 > missing }} {{ 0 and missing }} {{ 1 or missing }}\n'
      '{% macro m(a, b) %}{{ a is defined }}{{ b is defined }}{{ b|default("B") }}{% endmacro %}{{ m(1) }} {{ m(missing, 2) }} {{ m(b=1) }}'))
add('dict_iteration_and_repr', {'d': {'b': 1, 'a': [1, 2], 'c': {'x': None, 'y': True}, 'z': ''},
                                'l': [1, 'a', True, None, 1.5, "it's", 'say "hi"', 'both\'"', 'tab\tnl\ncr\rbs\\'], 'e': {}, 'el': []},
    T('{% for k in d %}{{ k }}={{ d[k] }};{% endfor %}\n{{ d }}\n{{ l }}\n{{ e }} {{ el }} {{ [[], [[]], e] }} {{ d.a }} {{ d.c }}\n'
      '{{ d|length }} {{ d|first }} {{ "b" in d }} {% for k in d|sort %}{{ k }}{% endfor %} {{ d|join("") }} {{ d|reverse|first }}'))
add('range_builtin', {'n': 4},
    T('{{ range(3)|join(",") }} {{ range(1, n)|join(",") }} {{ range(n, 1)|length }} {{ range(0)|length }} {{ range(0, 10, 3)|join(",") }} {{ range(5, 0, -2)|join(",") }}\n'
      '{% for i in range(n) %}{{ i }}{{ loop.index }}{% endfor %} {{ range(3)|first }} {{ range(3)|last }} {{ range(3)|reverse|join }} {{ range(3)|sort|join }} {{ 2 in range(3) }} {{ range(4)[2] }} {{ range(4)[-1] }} {{ range(true, 3)|join }}'))
add('floats_printing', {'a': 1.0, 'b': 100.0, 'c': 1e300, 'd': 0.5, 'e': 123456789.125, 'f': -2.5},
    T('{{ a }} {{ b }} {{ c }} {{ d }} {{ e }} {{ f }} {{ a + 1 }} {{ a == 1 }} {{ 1000000000000000.0 }} {{ 10000000000000000.0 }} {{ 0.0001 }} {{ 0.00001 }}\n'
      '{{ 1.5 * 2 }} {{ 2 ** 0.5 }} {{ 10 / 4 }} {{ 1 / 8 }} {{ 3.0 }} {{ 2.5 * 4 }} {{ 1000.0|int }} {{ "1.5"|int }} {{ [1.0, 2.25]|join(",") }} {{ [0.5, 1.5] }} {{ 3.7|int + 0.5 }} {{ 5 // 2.0 }} {{ 7 % 2.5 }} {{ -0.5 }} {{ 1.5 > 1 }} {{ 2.0 == 2 }}'))
add('string_ops', {'s': 'Hello', 'n': 3, 'w': 'a-b-c'},
    T('{{ s ~ " " ~ s|lower }} {{ s * n }} {{ n * "ab" }} {{ s[0] ~ s[-1] }} {{ s[1] }} {{ "ll" in s }} {{ "LL" in s }} {{ s|length * 2 }} '
      '{{ w|replace("-", "+") }} {{ w|reverse }} {{ w|upper|replace("B", "b") }} {{ s|first|lower ~ s|last|upper }} {{ (s ~ s)|length }}\n'
      '{{ "a" < "b" }} {{ "abc" < "abd" }} {{ "abc" < "ab" }} {{ "Z" < "a" }} {{ "" < "a" }} {{ "a" == "a" }} {{ "a" != "b" }} {{ "é"|length }} {{ "日本語"|reverse }} {{ "日本語"|first }}'))
add('braces_in_text', {'x': 1},
    T('{ {{ x }} } {{ "}}" }} {{ "{{" }} { x } {{ "%}" }} {{ "#}" }} {#- {{ -#}}\n[{{ x }}}] {{ "a" ~ "}" }} }} %} #} {'))
add('tag_lexing_whitespace', {'x': 1},
    T('{{x}}{{\tx\t}}{{\n x\n}}{%set y=2%}{{y}}{%-if\ny-%}\nok{%endif%}{{ [ 1 , 2 ]|join ( "," ) }}{{x|upper}}{{ (x)|int }}{{ "a"|replace("a","b") }}'))
add('unknown_filter_in_unused_template_is_fine', {}, T('ok', unused='{{ 1|nope }} {% if %} {{ unclosed'))
add('syntax_error_in_unused_template_is_fine', {'x': 1},
    T('{{ x }} {% if x %}{% include "good" %}{% else %}{% include "bad" %}{% endif %}', good='G', bad='{% for %}'))
add('macro_call_in_set_after_extends', {'x': 'ctx'},
    T('{% macro m(x) %}<{{ x }}>{% endmacro %}{% extends "base" %}{% set v = m(1) ~ m(2) %}{% macro n() %}N{% include "inc" %}{% endmacro %}'
      '{% set w = n()|lower %}{% block body %}{{ v }}{{ w }}{{ m(x) }}{% endblock %}', base='[{% block body %}{% endblock %}]', inc='I{{ x }}'))
add('for_else_loop_scoping', {'l': [1, 2]},
    T('{% for x in [] %}{% else %}{{ loop is defined }}{% endfor %}|{% for a in l %}{% for b in [] %}x{% else %}{{ loop.index }}{% endfor %}'
      '{% for b in [] %}{{ loop.index }}{% else %}[{{ loop.index }}{{ loop.last }}]{% endfor %}{% endfor %}'))
add('compare_chain_short_circuit', {'l': [1]},
    T('{{ 1 > 2 > 1 / 0 }}|{{ "a" in "b" == missing.x }}|{{ 2 < 1 < 1 / 0 }}|{{ 1 < 2 < 3 }}'))
add('extends_child_macro_sees_parent_set', {'x': 'X'},
    T('{% extends "mid" %}{% macro cm() %}c:{{ pv }}{{ mv }}{{ x }}{% endmacro %}{% block b %}{{ cm() }} {{ mm() }} {{ super() }}{% endblock %}',
      mid='{% extends "base" %}{% macro mm() %}m:{{ pv }}{% endmacro %}{% set mv = "MV" %}{% block b %}{{ mm() }}{{ super() }}{% endblock %}',
      base='{% set pv = "PV" %}[{% block b %}{{ pv }}{% endblock %}]'))
add('elif_short_circuit_and_number_edges', {},
    T('{% if true %}x{% elif missing %}y{% endif %}{% if false %}a{% elif true %}b{% elif missing %}c{% else %}d{% endif %}\n'
      '{{ 0.0 * -1 }} [{{ "ab" * -1 }}] {{ -7.5 % 2 }} {{ 7.5 % -2 }} {{ -7.5 // 2 }} {{ 2 ** 0 }} {{ 0 ** 0 }} {{ 1.5 ** 2 }} {{ 10 % 3.0 }} {{ -7 // -2 }} {{ 7 // -2 }} {{ 10000000000000000.0 }} {{ 1.0 * 1000000000000000 }} {{ 123456789012345678.0 }}'))

# ---------------------------------------------------------------------------
# Hand-written cases: errors
# ---------------------------------------------------------------------------
add('error_undefined_variable', {'a': 1}, T('a={{ a }} b={{ b }}'))
add('error_undefined_attribute', {'d': {'k': 1}}, T('{{ d.k }} {{ d.missing }}'))
add('error_undefined_chain', {'d': {}}, T('{{ d.a.b is defined }}'))
add('error_undefined_in_condition', {}, T('{% if missing %}x{% endif %}'))
add('error_undefined_in_loop', {}, T('{% for x in missing %}{% else %}else does not help{% endfor %}'))
add('error_undefined_loop_outside', {}, T('{{ loop.index }}'))
add('error_undefined_macro_param', {}, T('{% macro m(a, b) %}{{ a }}{{ b }}{% endmacro %}{{ m(1) }}'))
add('error_undefined_macro_name', {}, T('{{ nomacro(1) }}'))
add('error_undefined_after_output', {'items': [1, 2, 3]}, T('{% for i in items %}{{ i }}\n{% endfor %}{{ items[3] }}'))
add('error_undefined_super_without_parent', {}, T('{% block x %}{{ super() }}{% endblock %}'))
add('error_undefined_comparison', {}, T('{{ missing == 1 }}'))
add('error_undefined_filter_input', {}, T('{{ missing|upper }}'))
add('error_undefined_in_included', {'ok': 1}, T('{{ ok }}{% include "inc" %}', inc='{{ ok }}{{ nope }}'))
add('error_syntax_unclosed_variable', {'x': 1}, T('a {{ x '))
add('error_syntax_unclosed_block_tag', {'x': 1}, T('a {% if x '))
add('error_syntax_unclosed_comment', {}, T('a {# never closed'))
add('error_syntax_missing_endif', {}, T('{% if true %}a'))
add('error_syntax_missing_endfor', {}, T('{% for x in [1] %}{{ x }}'))
add('error_syntax_dangling_endif', {}, T('a{% endif %}'))
add('error_syntax_else_without_if', {}, T('{% else %}'))
add('error_syntax_unknown_tag', {}, T('{% frobnicate %}'))
add('error_syntax_bad_expression', {}, T('{{ 1 + }}'))
add('error_syntax_empty_expression', {}, T('{{ }}'))
add('error_syntax_unterminated_string', {}, T('{{ "abc }}'))
add('error_syntax_bad_operator', {}, T('{{ 1 & 2 }}'))
add('error_syntax_endblock_name_mismatch', {}, T('{% block a %}x{% endblock b %}'))
add('error_syntax_duplicate_block', {}, T('{% block a %}x{% endblock %}{% block a %}y{% endblock %}'))
add('error_syntax_keyword_before_positional', {}, T('{% macro m(a, b) %}{% endmacro %}{{ m(a=1, 2) }}'))
add('error_syntax_unknown_test', {'x': 1}, T('{{ x is frobnicated }}'))
add('error_syntax_in_included_template', {}, T('start{% include "broken" %}', broken='{% if %}'))
add('error_syntax_in_parent_template', {}, T('{% extends "broken" %}{% block a %}x{% endblock %}', broken='{% block a %}{% endblock'))
add('error_syntax_set_without_value', {}, T('{% set x %}'))
add('error_syntax_for_without_in', {}, T('{% for x [1] %}{% endfor %}'))
add('error_syntax_after_output', {'x': 1}, T('{{ x }}\n{{ x }}\n{% if x %}{% endfor %}'))
add('error_filter_unknown', {'x': 'a'}, T('{{ x|shout }}'))
add('error_filter_unknown_in_uncalled_macro_is_checked', {}, T('{% macro m() %}{{ 1|nope }}{% endmacro %}never called'))
add('error_filter_unknown_in_empty_loop_is_checked', {'e': []}, T('{% for x in e %}{{ x|frobnicate }}{% endfor %}'))
add('error_filter_after_output', {'x': 'a'}, T('{{ x }}{{ x|titlecase }}'))
add('error_filter_in_included', {}, T('ok{% include "inc" %}', inc='{{ 1|nope }}'))
add('error_filter_in_default_expression', {}, T('{% macro m(a=1|nope) %}{% endmacro %}'))
add('error_template_missing_include', {}, T('a{% include "nope" %}b'))
add('error_template_missing_extends', {}, T('{% extends "nope" %}'))
add('error_template_dynamic_include', {'which': 'x'}, T('{% include which %}', y='Y'))
add('error_type_string_plus_int', {}, T('{{ "a" + 1 }}'))
add('error_type_division_by_zero', {'z': 0}, T('{{ 1 / z }}'))
add('error_type_modulo_by_zero', {}, T('{{ 5 % 0 }}'))
add('error_type_floor_div_by_zero', {}, T('{{ 5 // 0 }}'))
add('error_type_compare_string_int', {}, T('{{ "a" < 1 }}'))
add('error_type_iterate_int', {'n': 5}, T('{% for i in n %}{{ i }}{% endfor %}'))
add('error_type_iterate_none', {'n': None}, T('{% for i in n %}{{ i }}{% endfor %}'))
add('error_type_length_of_int', {}, T('{{ 5|length }}'))
add('error_type_macro_too_many_args', {}, T('{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, 2) }}'))
add('error_type_macro_unknown_keyword', {}, T('{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, b=2) }}'))
add('error_type_macro_duplicate_argument', {}, T('{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, a=2) }}'))
add('error_type_call_non_macro', {'x': 5}, T('{{ x() }}'))
add('error_type_filter_extra_argument', {}, T('{{ "a"|upper(1) }}'))
add('error_type_filter_missing_argument', {}, T('{{ "a"|replace("a") }}'))
add('error_type_in_string_with_non_string', {}, T('{{ 1 in "abc" }}'))
add('error_type_in_none', {}, T('{{ "a" in none }}'))
add('error_type_unary_minus_binds_tighter_than_filter', {'x': '3'}, T('{{ -x|int }}'))
add('error_type_neg_string', {}, T('{{ -"a" }}'))
add('error_type_sort_mixed', {}, T('{{ [1, "a"]|sort }}'))
add('error_type_range_string', {}, T('{{ range("3") }}'))
add('error_type_super_with_args', {}, T('{% extends "b" %}{% block x %}{{ super(1) }}{% endblock %}', b='{% block x %}p{% endblock %}'))
add('error_type_include_non_string', {}, T('{% include 5 %}'))
add('error_type_concat_prec', {}, T('{{ 1 + 2 ~ 3 }}'))
add('error_type_join_int', {}, T('{{ 5|join }}'))
add('error_syntax_wins_over_filter', {}, T('{{ 1|nope }}{% if %}'))
add('error_filter_before_runtime_error', {}, T('{{ missing }}{{ 1|nope }}'))
add('error_syntax_triple_brace', {'x': 1}, T('{{{ x }}}'))
add('error_syntax_extends_twice', {}, T('{% extends "b" %}{% extends "b" %}', b='B'))
add('error_syntax_extends_in_macro', {}, T('{% macro m() %}{% extends "b" %}{% endmacro %}', b='B'))
add('error_syntax_nested_duplicate_block', {}, T('{% block a %}{% block a %}x{% endblock %}{% endblock %}'))
add('error_syntax_macro_duplicate_param', {}, T('{% macro m(a, a) %}{% endmacro %}'))
add('error_syntax_duplicate_keyword_argument', {}, T('{% macro m(a) %}{% endmacro %}{{ m(a=1, a=2) }}'))
add('error_syntax_endfor_extra_tokens', {'l': [1]}, T('{% for i in l %}{% endfor i %}'))
add('error_type_reverse_none', {}, T('{{ none|reverse }}'))


# ---------------------------------------------------------------------------
# Generated cases
# ---------------------------------------------------------------------------
def gen_int_expr(rng, depth):
    """A random integer-valued expression; values stay small and divisors nonzero."""
    if depth <= 0 or rng.random() < 0.3:
        r = rng.random()
        if r < 0.5:
            return str(rng.randint(0, 20))
        if r < 0.7:
            return rng.choice(['a', 'b', 'c', 'n'])
        if r < 0.8:
            return '-' + str(rng.randint(1, 9))
        if r < 0.9:
            return rng.choice(['"7"|int', '"-2"|int', 'l|length', 's|length', 'l[0]', 'l[-1]', 'true', 'false', '3.9|int', 'l|first', 'l|last', '(l|sort)[1]'])
        return rng.choice(['true|int', 'range(5)|length', '(1 < 2)|int', '(a > b)|int'])
    op = rng.choice(['+', '-', '*', '//', '%', '**', 'paren', 'neg'])
    left = gen_int_expr(rng, depth - 1)
    if op == 'paren':
        return '(' + left + ')'
    if op == 'neg':
        return '-(' + left + ')'
    if op == '**':
        return '(' + gen_int_expr(rng, 0) + ') ** ' + str(rng.randint(0, 3))
    if op in ('//', '%'):
        return '(' + left + ') ' + op + ' ' + rng.choice(['3', '-3', '7', '2', '-1', '(b + 1)'])
    if op == '*':
        return '(' + left + ') * ' + str(rng.randint(-3, 3))
    return '(' + left + ') ' + op + ' (' + gen_int_expr(rng, depth - 1) + ')'


def gen_bool_expr(rng, depth):
    if depth <= 0 or rng.random() < 0.3:
        r = rng.random()
        if r < 0.5:
            return gen_int_expr(rng, 1) + ' ' + rng.choice(['<', '<=', '>', '>=', '==', '!=']) + ' ' + gen_int_expr(rng, 1)
        if r < 0.7:
            return rng.choice(['true', 'false', 'none', 'a', '0', '""', '"x"', '[]', 'l', 's'])
        if r < 0.85:
            return gen_int_expr(rng, 1) + ' in ' + rng.choice(['l', '[1, 2, 3]', 'range(4)', '[]'])
        return rng.choice(['"a" in s', '"zz" in s', '"k" in d', '"q" not in d', 'missing is defined', 'd.k is defined', 'd.q is not defined', 'l[9] is defined'])
    op = rng.choice(['and', 'or', 'not', 'chain', 'paren'])
    if op == 'not':
        return 'not ' + gen_bool_expr(rng, depth - 1)
    if op == 'paren':
        return '(' + gen_bool_expr(rng, depth - 1) + ')'
    if op == 'chain':
        return gen_int_expr(rng, 1) + ' ' + rng.choice(['<', '<=']) + ' ' + gen_int_expr(rng, 1) + ' ' + rng.choice(['<', '<=', '!=']) + ' ' + gen_int_expr(rng, 1)
    return gen_bool_expr(rng, depth - 1) + ' ' + op + ' ' + gen_bool_expr(rng, depth - 1)


def gen_str_expr(rng, depth):
    if depth <= 0 or rng.random() < 0.3:
        return rng.choice(['s', '"lit"', '"A b"', 'w', 's|upper', 's|lower', 'w|trim', 's[0]', 's|first', 's|last', 's|reverse', 'l|join(",")', 'd|join("-")', '(s ~ w)|length ~ ""', 'missing|default("dflt")'])
    op = rng.choice(['~', '~', 'replace', 'filter', 'mul', 'plus'])
    if op == '~':
        return '(' + gen_str_expr(rng, depth - 1) + ') ~ (' + rng.choice([gen_str_expr(rng, depth - 1), gen_int_expr(rng, 1), gen_bool_expr(rng, 1)]) + ')'
    if op == 'replace':
        return '(' + gen_str_expr(rng, depth - 1) + ')|replace(' + rng.choice(['"a"', '"l"', '" "', '"x"']) + ', ' + rng.choice(['"_"', '""', '"AA"']) + ')'
    if op == 'filter':
        return '(' + gen_str_expr(rng, depth - 1) + ')|' + rng.choice(['upper', 'lower', 'trim', 'reverse', 'escape'])
    if op == 'mul':
        return '(' + gen_str_expr(rng, depth - 1) + ') * ' + str(rng.randint(0, 3))
    return '(' + gen_str_expr(rng, depth - 1) + ') + (' + gen_str_expr(rng, depth - 1) + ')'


GEN_CTX = {'a': 3, 'b': 5, 'c': -2, 'n': 0, 'l': [4, 1, 3], 's': 'hello', 'w': '  wide  ', 'd': {'k': 1, 'j': 2}}


def gen_expressions(seed, count):
    rng = random.Random(seed)
    lines = []
    for i in range(count):
        kind = rng.random()
        if kind < 0.4:
            e = gen_int_expr(rng, rng.randint(1, 4))
        elif kind < 0.75:
            e = gen_bool_expr(rng, rng.randint(1, 3))
        else:
            e = gen_str_expr(rng, rng.randint(1, 3))
        lines.append('%d: {{ %s }}' % (i, e))
    return '\n'.join(lines)


for seed in range(3):
    add('gen_expressions_%d' % seed, GEN_CTX, T(gen_expressions(100 + seed, 250)))


def gen_structured_template(rng, depth, counter):
    """A random block of statements using variables from GEN2_CTX; returns template text."""
    out = []
    n = rng.randint(1, 4)
    for _ in range(n):
        k = rng.random()
        if depth <= 0 or k < 0.35:
            out.append(rng.choice([
                'T{{ x }}', '{{ y|upper }}', '{{ nums|length }}', '{{ nums|join("+") }}', ' plain text\n',
                '{{ names|first }}', '{{ x * 2 + 1 }}', '{{ x > 2 }}', '{{ names|sort|join }}', '{# c #}', '{{- "S" -}}', '\n  {{ y ~ x }}\n',
                '{% set tmp = x + 1 %}{{ tmp }}', '{{ missing|default(x) }}', '{{ d.k }}{{ d.q is defined }}']))
        elif k < 0.6:
            v = 'i%d' % counter[0]
            counter[0] += 1
            seq = rng.choice(['nums', 'names', 'range(3)', 'range(x)', 'd', 'y', '[]', 'nums|reverse', 'names|sort'])
            body = gen_structured_template(rng, depth - 1, counter)
            body = body.replace('{{ x }}', '{{ %s }}' % v)
            else_part = '{% else %}E' if rng.random() < 0.4 else ''
            strip = '-' if rng.random() < 0.3 else ''
            out.append('{%% for %s in %s %s%%}{{ loop.index }}/{{ loop.length }}:%s%s{%%%s endfor %%}' % (v, seq, strip, body, else_part, strip))
        elif k < 0.8:
            cond = rng.choice(['x > 2', 'y == "abc"', 'nums', 'not names', 'x % 2 == 0', 'missing is defined', 'd.k', 'x in nums', 'false', 'true'])
            body = gen_structured_template(rng, depth - 1, counter)
            elifs = ''
            if rng.random() < 0.5:
                elifs = '{%% elif %s %%}%s' % (rng.choice(['x', 'nums|length > 1', 'false']), gen_structured_template(rng, depth - 1, counter))
            else_part = ''
            if rng.random() < 0.5:
                else_part = '{% else %}' + gen_structured_template(rng, depth - 1, counter)
            out.append('{%% if %s %%}%s%s%s{%% endif %%}' % (cond, body, elifs, else_part))
        else:
            v = 'v%d' % counter[0]
            counter[0] += 1
            out.append('{%% set %s = %s %%}{{ %s }}' % (v, rng.choice(['x + 1', 'y ~ "!"', 'nums|first', '[x, y]', 'names|length']), v))
    return ''.join(out)


GEN2_CTX = {'x': 3, 'y': 'abc', 'nums': [5, 2, 9, 1], 'names': ['bob', 'Al', 'cy'], 'd': {'k': 'kv', 'm': [1, 2]}}


def gen_structured(seed):
    rng = random.Random(seed)
    counter = [0]
    macros = ('{% macro tag(name, val, sep=":") %}<{{ name }}{{ sep }}{{ val }}>{% endmacro %}'
              '{% macro rep(n, ch="*") %}{% for i in range(n) %}{{ ch }}{% endfor %}{% endmacro %}')
    parts = [macros]
    for _ in range(12):
        parts.append(gen_structured_template(rng, 3, counter))
        parts.append(rng.choice(['\n', '{{ tag("x", x) }}\n', '{{ rep(x) }}\n', '{{ tag("n", nums|length, sep="=") }}\n', '{% include "sub" %}\n']))
    sub = '[sub {{ x }} {{ y|upper }}{% for n in nums %}{{ n }}{% endfor %}{% if names %}{{ names|first }}{% endif %}]'
    return T(''.join(parts), sub=sub)


for seed in range(3):
    add('gen_structured_%d' % seed, GEN2_CTX, gen_structured(200 + seed))


def gen_inheritance(seed):
    """A random inheritance chain with nested blocks and super() calls."""
    rng = random.Random(seed)
    names = ['b%d' % i for i in range(8)]
    levels = ['base', 'mid1', 'mid2', 'main']
    templates = {}
    base_parts = ['<base>']
    for nm in names:
        if rng.random() < 0.3 and nm != names[0]:
            base_parts.append('{%% block %s %%}base-%s({%% block %s_in %%}in-%s{%% endblock %%}){%% endblock %%}\n' % (nm, nm, nm, nm))
        else:
            base_parts.append('{%% block %s %%}base-%s{%% endblock %%}\n' % (nm, nm))
    templates['base'] = ''.join(base_parts) + '{% block tail %}tail{% endblock %}'
    parent = 'base'
    for lvl in levels[1:]:
        parts = ['{%% extends "%s" %%}\n' % parent, '{%% set lvl_%s = "%s" %%}' % (lvl, lvl)]
        for nm in names + [n + '_in' for n in names] + ['tail']:
            if rng.random() < 0.45:
                sup = '{{ super() }}' if rng.random() < 0.7 else ''
                inner = rng.choice(['', '{{ lvl_' + lvl + ' }}', '{{ x }}', '{% for i in range(2) %}{{ i }}{% endfor %}', '{{ m() }}'])
                parts.append('{%% block %s %%}%s[%s%s]{%% endblock %%}\n' % (nm, lvl, sup, inner))
        if lvl == 'main' or rng.random() < 0.5:
            parts.append('{% macro m() %}M-' + lvl + '{% endmacro %}')
        templates[lvl] = ''.join(parts)
        parent = lvl
    order = ['main', 'mid2', 'mid1', 'base']
    return [(n, templates[n]) for n in order]


for seed in range(3):
    add('gen_inheritance_%d' % seed, {'x': 'X'}, gen_inheritance(300 + seed))


# ---------------------------------------------------------------------------
# Large cases
# ---------------------------------------------------------------------------
def big_items(rng, count):
    words = ['alpha', 'Beta', 'gamma', 'DELTA', 'eps', 'zeta', 'eta', 'theta', 'iota', 'kappa', 'lambda', 'mu']
    items = []
    for i in range(count):
        items.append({'id': i, 'name': rng.choice(words) + str(rng.randint(0, 999)), 'qty': rng.randint(0, 50),
                      'price': rng.randint(1, 10000), 'tags': rng.sample(words, rng.randint(0, 3)),
                      'active': rng.random() < 0.7, 'note': rng.choice(['', ' <b>&"x"</b> ', 'plain', '  padded  '])})
    return items


rng = random.Random(400)
add('large_loop_20k', {'items': big_items(rng, 20000), 'title': 'Inventory'}, T(
    '{% macro money(cents) %}{{ cents // 100 }}.{% if cents % 100 < 10 %}0{% endif %}{{ cents % 100 }}{% endmacro -%}\n'
    '{{ title|upper }}\n'
    '{% for it in items -%}\n'
    '{{ loop.index }}. {{ it.name|lower }} x{{ it.qty }} @ {{ money(it.price) }} = {{ money(it.qty * it.price) }}'
    '{% if it.tags %} [{{ it.tags|sort|join(",") }}]{% endif %}{% if not it.active %} (inactive){% endif %}'
    '{% if it.note|trim %} note={{ it.note|trim|escape }}{% endif %}{% if loop.first %} FIRST{% elif loop.last %} LAST{% endif %}\n'
    '{% endfor -%}\n'
    'count={{ items|length }} last={{ (items|last).name }} first={{ (items|first).id }}'), compact=True)

rng = random.Random(401)
add('large_nested_loops', {'rows': [[rng.randint(0, 99) for _ in range(220)] for _ in range(220)]}, T(
    '{% for row in rows %}{% for v in row %}{% if v % 7 == 0 %}{{ v }}{% if not loop.last %},{% endif %}{% endif %}{% endfor %} | {{ row|sort|first }}-{{ row|sort|last }} #{{ loop.index }}\n{% endfor %}'), compact=True)

rng = random.Random(402)
big_tpl_parts = ['{% macro cell(v, w=4) %}{{ v }}{% if v < 10 %}   {% elif v < 100 %}  {% else %} {% endif %}{% endmacro %}']
for i in range(12000):
    k = rng.random()
    if k < 0.3:
        big_tpl_parts.append('line %d: {{ cell(%d) }}{{ vals[%d] }}\n' % (i, rng.randint(0, 999), rng.randint(0, 99)))
    elif k < 0.5:
        big_tpl_parts.append('{%% if vals[%d] > 50 %%}hi{%% else %%}lo{%% endif %%} {{- "" }}\n' % rng.randint(0, 99))
    elif k < 0.7:
        big_tpl_parts.append('{%% set t%d = vals[%d] * 2 %%}{{ t%d }} {# comment %d #}\n' % (i, rng.randint(0, 99), i, i))
    elif k < 0.85:
        big_tpl_parts.append('{% for q in range(3) -%} {{ q }} {%- endfor %}\n')
    else:
        big_tpl_parts.append('{% include "snippet" %}\n')
add('large_template_50k_tags', {'vals': [random.Random(403).randint(0, 100) for _ in range(100)]},
    T(''.join(big_tpl_parts), snippet='({{ vals|first }},{{ vals|last }})'), compact=True)


def make_tree(rng, depth, width):
    node = {'name': 'n%d' % rng.randint(0, 9999), 'value': rng.randint(0, 100), 'children': []}
    if depth > 0:
        for _ in range(rng.randint(1, width)):
            node['children'].append(make_tree(rng, depth - 1, width))
    return node


rng = random.Random(404)
add('large_macro_recursion_tree', {'tree': make_tree(rng, 9, 4)}, T(
    '{% macro render(node, depth) %}{{ "  " * depth }}{{ node.name }}={{ node.value }}{% if node.children %} ({{ node.children|length }}){% endif %}\n'
    '{% for c in node.children %}{{ render(c, depth + 1) }}{% endfor %}{% endmacro %}'
    '{% macro total(node) %}{{ node.value + sum_rest(node.children, 0)|int }}{% endmacro %}'
    '{% macro sum_rest(list, i) %}{% if i < list|length %}{{ total(list[i])|int + sum_rest(list, i + 1)|int }}{% else %}0{% endif %}{% endmacro %}'
    '{% macro loop_set_demo(node) %}{% set acc = node.value %}{% for c in node.children %}{% set acc = acc + c.value %}{% endfor %}{{ acc }}{% endmacro %}'
    '{% macro count(node) %}{{ 1 + count_rest(node.children, 0)|int }}{% endmacro %}'
    '{% macro count_rest(list, i) %}{% if i < list|length %}{{ count(list[i])|int + count_rest(list, i + 1)|int }}{% else %}0{% endif %}{% endmacro %}'
    '{{ render(tree, 0) }}total={{ total(tree) }} nodes={{ count(tree) }} demo={{ loop_set_demo(tree) }}'), compact=True)

rng = random.Random(405)
add('large_deep_macro_recursion', {'n': 100}, T(
    '{% macro count(n) %}{% if n > 0 %}{{ n }},{{ count(n - 1) }}{% else %}done{% endif %}{% endmacro %}'
    '{% macro depth(n) %}{% if n == 0 %}0{% else %}{{ depth(n - 1)|int + 1 }}{% endif %}{% endmacro %}'
    '{{ count(n) }}\n{{ depth(n) }}\n{% for i in range(200) %}{{ depth(50)|int * i }} {% endfor %}'))

rng = random.Random(406)
inh_templates = []
block_names = ['blk%d' % i for i in range(300)]
base_body = ''.join('{%% block %s %%}base%d{%% endblock %%}\n' % (b, i) for i, b in enumerate(block_names))
inh_templates.append(('base', base_body))
parent = 'base'
for lvl in range(6):
    name = 'level%d' % lvl
    body = ['{%% extends "%s" %%}\n' % parent]
    for i, b in enumerate(block_names):
        if rng.random() < 0.5:
            body.append('{%% block %s %%}L%d[{{ super() }}]{%% endblock %%}\n' % (b, lvl))
    inh_templates.append((name, ''.join(body)))
    parent = name
inh_templates.reverse()
add('large_inheritance_chain', {}, inh_templates)

rng = random.Random(407)
long_text = ''.join(rng.choice('abcdefghij <>&"\' \n') for _ in range(200000))
add('large_string_filters', {'text': long_text, 'words': [''.join(rng.choice('abcXYZ') for _ in range(6)) for _ in range(30000)]}, T(
    '{{ text|escape|length }}\n{{ text|upper|replace("A", "4")|replace("<", "[")|length }}\n{{ text|trim|reverse|first }}\n'
    '{{ words|sort|first }} {{ words|sort|last }} {{ words|join("")|length }} {{ words|reverse|first }} {{ (words|join(" ")|upper|replace("X", ""))|length }}\n'
    '{% for w in words|sort %}{% if loop.index % 5000 == 0 %}{{ loop.index }}:{{ w }} {% endif %}{% endfor %}'), compact=True)


# ---------------------------------------------------------------------------
# Oracle (Jinja2) and driver
# ---------------------------------------------------------------------------
ORACLE_CODE = r'''
import json, sys
from jinja2 import Environment, DictLoader, StrictUndefined, TemplateSyntaxError, TemplateAssertionError, UndefinedError, TemplateNotFound, TemplatesNotFound, TemplateRuntimeError
from jinja2.exceptions import FilterArgumentError

def split_input(data):
    lines = data.split('\n')
    if data.endswith('\n'):
        lines.pop()
    sep = lines.index('--')
    context = json.loads('\n'.join(lines[:sep]))
    templates, order, name, body = {}, [], None, []
    for line in lines[sep + 1:]:
        if line.startswith('=== '):
            if name is not None:
                templates[name] = '\n'.join(body)
            name = line[4:]; order.append(name); body = []
        elif name is not None:
            body.append(line)
    if name is not None:
        templates[name] = '\n'.join(body)
    return context, templates, order

def oracle(data):
    context, templates, order = split_input(data)
    env = Environment(loader=DictLoader(templates), undefined=StrictUndefined, keep_trailing_newline=True,
                      trim_blocks=False, lstrip_blocks=False, autoescape=False)
    try:
        return env.get_template(order[0]).render(context)
    except TemplateAssertionError as e:
        return 'error: filter' if str(e).startswith('No filter named') else 'error: syntax'
    except TemplateSyntaxError:
        return 'error: syntax'
    except UndefinedError:
        return 'error: undefined'
    except (TemplateNotFound, TemplatesNotFound):
        return 'error: template'
    except FilterArgumentError:
        return 'error: type'
    except TemplateRuntimeError as e:
        if 'No filter named' in str(e):
            return 'error: filter'
        if str(e) == 'extended multiple times':
            return 'error: syntax'
        raise
    except SyntaxError:
        # Jinja2 reports duplicate macro parameters and repeated keyword
        # arguments by failing to compile the generated Python.
        return 'error: syntax'
    except (TypeError, ZeroDivisionError, ValueError, OverflowError):
        return 'error: type'

sys.setrecursionlimit(20000)
sys.stdout.write(oracle(sys.stdin.read()) + '\n')
'''


def oracle_python():
    try:
        import jinja2  # noqa: F401
        return sys.executable
    except ImportError:
        pass
    if os.path.exists(ORACLE_PY):
        return ORACLE_PY
    sys.exit('jinja2 is needed for the oracle: run with the .oracle-venv interpreter')


def run(cmd, data):
    proc = subprocess.run(cmd, input=data.encode('utf-8'), capture_output=True, timeout=600)
    if proc.returncode != 0:
        sys.exit('command failed: %s\n%s' % (cmd, proc.stderr.decode('utf-8', 'replace')[-2000:]))
    return proc.stdout.decode('utf-8')


def normalize(text):
    return '\n'.join(line.rstrip() for line in text.split('\n')).rstrip('\n')


def main():
    opy = oracle_python()
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(TESTS, f))
    names = set()
    total = 0
    for idx, (name, data) in enumerate(cases, 1):
        assert name not in names, name
        names.add(name)
        base = '%03d_%s' % (idx, name)
        expected = run([sys.executable, REF], data)
        oracle_out = run([opy, '-c', ORACLE_CODE], data)
        if normalize(expected) != normalize(oracle_out):
            sys.exit('ORACLE DISAGREES on %s\n--- reference:\n%s\n--- jinja2:\n%s' % (base, expected[:1500], oracle_out[:1500]))
        if name.startswith('error_'):
            assert expected.startswith('error: '), base
            assert expected.startswith('error: ' + name.split('_')[1]), base
        else:
            assert not expected.startswith('error: '), base + ' ' + expected[:100]
        with open(os.path.join(TESTS, base + '.in'), 'w', encoding='utf-8') as f:
            f.write(data)
        with open(os.path.join(TESTS, base + '.out'), 'w', encoding='utf-8') as f:
            f.write(expected)
        total += len(data) + len(expected)
        print('%-55s %8d bytes -> %s' % (base, len(data), expected[:50].replace('\n', '\\n')))
    print('%d tests written, %.1f MB' % (len(cases), total / 1e6))


if __name__ == '__main__':
    main()
