import pytest


def test_text_and_variables(render):
    assert render("Hello {{ name }}!", {"name": "Ada"}) == "Hello Ada!"
    assert render("") == ""


@pytest.mark.parametrize(
    "expr, expected",
    [
        ("1 + 2 * 3", "7"),
        ("7 / 2", "3.5"),
        ("7 // 2", "3"),
        ("-7 % 3", "2"),
        ("-2 ** 2", "4"),
        ("2 ** -1", "0.5"),
        ("0 or 'x'", "x"),
        ("'' and 1", ""),
        ("1 and 2", "2"),
        ("not 1 == 2", "True"),
        ("1 < 2 < 3", "True"),
        ("3 > 2 > 2", "False"),
        ("'a' ~ 1 ~ none", "a1None"),
        ("'a' ~ 1 * 2", "a2"),
        ("'b' in 'abc'", "True"),
        ("2 not in [1, 2]", "False"),
        ("[1, 'a'] == [1.0, 'a']", "True"),
        ("x is defined", "True"),
        ("nope is defined", "False"),
        ("nope is not defined", "True"),
        ("1 + nope is defined", "1"),
        ("[n, 's']", "[3, 's']"),
        ("user.tags[-1]", "y"),
        ("user['name']", "Ada"),
        ("user.name[0]", "A"),
        ("user.missing is defined", "False"),
        ("user.tags[5] is defined", "False"),
        ("n.x is defined", "False"),
        ("range(3)|join(',')", "0,1,2"),
        ("range(5, 0, -2)|join(',')", "5,3,1"),
    ],
)
def test_expressions(render, expr, expected):
    ctx = {"x": 1, "n": 3, "user": {"name": "Ada", "tags": ["x", "y"]}}
    assert render("{{ " + expr + " }}", ctx) == expected


def test_comparison_chain_short_circuits(render):
    assert render("{{ 1 > 2 > nope }}") == "False"
    assert render("{{ false and nope }}") == "False"
    assert render("{{ true or nope }}") == "True"


@pytest.mark.parametrize(
    "source, kind",
    [
        ("{{ nope }}", "undefined"),
        ("{{ a.b.c }}", "undefined"),
        ("{% if nope %}{% endif %}", "undefined"),
        ("{{ nope == 1 }}", "undefined"),
        ("{{ nope() }}", "undefined"),
        ("{% for i in nope %}{% endfor %}", "undefined"),
        ("{{ a[nope] }}", "undefined"),
        ("{{ x() }}", "type"),
        ("{{ 1 + 'a' }}", "type"),
        ("{{ 1 / 0 }}", "type"),
        ("{% for i in 5 %}{% endfor %}", "type"),
        ("{{ range() }}", "type"),
        ("{{ range(1, 2, 0) }}", "type"),
        ("{{ range(1.0) }}", "type"),
        ("{{ range(1, k=2) }}", "type"),
        ("{{ nope() + 1 }}", "undefined"),
        ("{{ loop }}", "undefined"),
        ("{{ super() }}", "undefined"),
        ("{% include 'zzz' %}", "template"),
        ("{% include 5 %}", "type"),
        ("{% include nope %}", "undefined"),
        ("{{ x(a.c.d) }}", "undefined"),
        ("{{ x(nope) }}", "type"),
        ("{% if 1 %}", "syntax"),
    ],
)
def test_errors(error_kind, source, kind):
    assert error_kind(source, {"a": {"b": 1}, "x": 1}) == kind


def test_if_elif_else(render):
    src = "{% if n == 1 %}one{% elif n == 2 %}two{% else %}many{% endif %}"
    assert [render(src, {"n": i}) for i in (1, 2, 3)] == ["one", "two", "many"]


def test_for_loop_variables(render):
    src = "{% for t in items %}{{ loop.index }}/{{ loop.index0 }}/{{ loop.first }}/{{ loop.last }}/{{ loop.length }}:{{ t }} {% endfor %}"
    assert render(src, {"items": ["a", "b"]}) == "1/0/True/False/2:a 2/1/False/True/2:b "


def test_for_over_dict_and_string_and_else(render):
    assert render("{% for k in d %}{{ k }}{% endfor %}", {"d": {"z": 1, "a": 2}}) == "za"
    assert render("{% for c in 'héy' %}[{{ c }}]{% endfor %}") == "[h][é][y]"
    assert render("{% for i in [] %}x{% else %}empty{% endfor %}") == "empty"


def test_nested_loops_use_innermost_loop(render):
    src = "{% for a in [1, 2] %}{% for b in [1, 2, 3] %}{{ loop.length }}{% endfor %}{{ loop.length }}{% endfor %}"
    assert render(src) == "33323332"


def test_set_scoping(render):
    assert render("{% set a = 1 %}{{ a }}") == "1"
    src = "{% set a = 1 %}{% for i in [1] %}{% set a = 2 %}{{ a }}{% endfor %}{{ a }}"
    assert render(src) == "21"
    assert render("{% if true %}{% set a = 1 %}{% endif %}{{ a }}") == "1"


def test_whitespace_control(render):
    assert render("a  {{- 1 -}}  b") == "a1b"
    assert render("a\n{%- if true -%}\n b\n{%- endif %}\n") == "ab\n"
    assert render("  {# c #}  ") == "    "


def test_macros(render):
    src = "{% macro f(a, b=a ~ '!') %}[{{ a }}{{ b }}]{% endmacro %}{{ f(1) }}{{ f(1, 2) }}{{ f(b=3, a=4) }}"
    assert render(src) == "[11!][12][43]"


def test_macro_recursion_returns_string(render):
    src = "{% macro fact(n) %}{% if n <= 1 %}1{% else %}{{ n * fact(n - 1)|int }}{% endif %}{% endmacro %}{{ fact(10) }}"
    assert render(src) == "3628800"


def test_macro_sees_later_sets_but_not_caller_locals(render, error_kind):
    src = "{% macro m() %}{{ late }}{% endmacro %}{% set late = 'L' %}{{ m() }}"
    assert render(src) == "L"
    src = "{% macro m() %}{{ v }}{% endmacro %}{% for v in [1] %}{{ m() }}{% endfor %}"
    assert error_kind(src) == "undefined"


def test_macro_unsupplied_parameter_is_undefined(render, error_kind):
    assert render("{% macro m(a) %}{{ a is defined }}{% endmacro %}{{ m() }}") == "False"
    assert error_kind("{% macro m(a) %}{{ a }}{% endmacro %}{{ m() }}") == "undefined"


@pytest.mark.parametrize(
    "call",
    ["m(1, 2)", "m(b=1)", "m(1, a=2)"],
)
def test_macro_call_type_errors(error_kind, call):
    assert error_kind("{% macro m(a) %}{% endmacro %}{{ " + call + " }}") == "type"


def test_include_shares_scope_one_way(render):
    assert render("{% set a = 1 %}{% include 'sub' %}{{ b is defined }}", sub="{{ a }}{% set b = 2 %}") == "1False"


def test_include_in_loop_sees_loop_variables(render):
    assert render("{% for i in [1, 2] %}{% include 'sub' %}{% endfor %}", sub="<{{ i }}>") == "<1><2>"


def test_unused_template_may_be_broken(render, error_kind):
    assert render("ok", other="{% if %}") == "ok"
    assert error_kind("{% include 'o' %}", o="{% if %}") == "syntax"
    assert error_kind("{% include 'o' %}", o="{{ 1|nope }}") == "filter"


def test_inheritance_example(render):
    page = (
        '{% extends "base" %}\n{% set count = items|length %}\n'
        "{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}"
    )
    base = (
        "{% macro item(v) %}#{{ v }}{% endmacro -%}\n"
        "<h1>{% block title %}{{ title }}{% endblock %}</h1>\n"
        "{% block body %}{{ count }} items{% endblock %}\n"
        '{% include "footer" %}'
    )
    footer = '-- {{ title|lower }} {{ missing|default("end") }}'
    out = render(page, {"title": "T", "items": [3, 1, 2]}, base=base, footer=footer)
    assert out == "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end"


def test_three_level_chain_and_super(render):
    gc = '{% extends "c" %}{% block x %}G({{ super() }}){% endblock %}'
    c = '{% extends "b" %}{% block x %}C({{ super() }}){% endblock %}'
    b = "[{% block x %}B{% endblock %}]"
    assert render(gc, c=c, b=b) == "[G(C(B))]"


def test_child_output_before_extends_kept_and_after_dropped(render):
    child = 'pre{% extends "p" %}dropped{{ 1 }}{% block a %}A{% endblock %}'
    assert render(child, p="<{% block a %}x{% endblock %}>") == "pre<A>"


def test_block_not_in_parent_never_renders(render):
    assert render('{% extends "p" %}{% block zz %}Z{% endblock %}', p="P") == "P"


def test_block_scope_is_template_scope(render, error_kind):
    src = "{% for i in [1] %}{% endfor %}{% block a %}{{ i is defined }}{% endblock %}"
    assert render(src) == "False"


def test_super_without_parent_block(error_kind):
    assert error_kind("{% block a %}{{ super() }}{% endblock %}") == "undefined"


def test_super_with_arguments(error_kind):
    assert error_kind('{% extends "p" %}{% block a %}{{ super(1) }}{% endblock %}', p="{% block a %}{% endblock %}") == "type"


def test_extends_errors(error_kind):
    assert error_kind('{% extends "zz" %}') == "template"
    assert error_kind("{% extends 5 %}") == "type"
    assert error_kind("{% extends nope %}") == "undefined"


def test_string_methods_are_not_attributes(render):
    assert render("{{ s.upper is defined }}", {"s": "x"}) == "False"
