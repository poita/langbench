import pytest

from sitegen.template import (
    Environment, FilterError, TemplateNotFound, TemplateSyntaxError,
    TemplateTypeError, UndefinedError,
)


def render(source, context=None, **templates):
    env = Environment({"main": source, **templates})
    return env.render("main", context or {})


# -- the worked examples of the specification ---------------------------------

def test_spec_example_loop_and_filters():
    source = (
        "Hi {{ user.name|upper }}!\n"
        "{% for t in user.tags -%}\n"
        "  {{ loop.index }}. {{ t }}\n"
        "{% endfor -%}\n"
        '{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %} '
        '{{ 7 / 2 }} {{ 7 // 2 }} {{ [n, "s"] }}'
    )
    context = {"user": {"name": "Ada", "tags": ["x", "y"]}, "n": 3}
    assert render(source, context) == "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']"


def test_spec_example_inheritance_macro_include():
    templates = {
        "page": (
            '{% extends "base" %}\n'
            "{% set count = items|length %}\n"
            "{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>"
            "{% endfor %}</ul>{% endblock %}"
        ),
        "base": (
            "{% macro item(v) %}#{{ v }}{% endmacro -%}\n"
            "<h1>{% block title %}{{ title }}{% endblock %}</h1>\n"
            "{% block body %}{{ count }} items{% endblock %}\n"
            '{% include "footer" %}'
        ),
        "footer": '-- {{ title|lower }} {{ missing|default("end") }}',
    }
    env = Environment(templates)
    out = env.render("page", {"title": "T", "items": [3, 1, 2]})
    assert out == "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end"


def test_spec_example_unclosed_for_is_a_syntax_error_before_any_output():
    with pytest.raises(TemplateSyntaxError):
        render("Hi\n{% for t in x -%}\n{{ t }}", {"x": [1]})


def test_spec_example_attribute_of_undefined():
    with pytest.raises(UndefinedError):
        render("{{ a.b }}{{ a.c.d }}", {"a": {"b": 1}})


# -- text, tags and whitespace control ------------------------------------------

def test_text_and_stray_braces():
    assert render("a { b } {x} }} {") == "a { b } {x} }} {"


def test_comments():
    assert render("a{# hi {{ not }} #}b") == "ab"
    with pytest.raises(TemplateSyntaxError):
        render("a{# unclosed")


def test_whitespace_control():
    assert render("a  {{- 1 -}}  b") == "a1b"
    assert render("a \n {%- if true -%} \n x \n {%- endif -%} \n b") == "axb"
    assert render("a {#- c -#} b") == "ab"
    assert render("a {{ 1 }}  b") == "a 1  b"
    # Only the adjacent text is trimmed, never across another tag.
    assert render("{{ 1 }} {{- 2 }}") == "12"
    assert render("{{ 1 }} {{ 2 -}} {{ 3 }}") == "1 23"


def test_minus_before_closer_needs_adjacency():
    with pytest.raises(TemplateSyntaxError):
        render("{{ 1 - }}")


def test_string_containing_closer():
    assert render('{{ "%}" }}{{ "}}" }}') == "%}}}"


@pytest.mark.parametrize(
    "source",
    [
        "{{ 1", "{{{ x }}}", "{% if %}", "{% endif %}", "{% raw %}", "{% foo %}", "{%%}",
        "{% if true %}", "{% for x in y %}{% endif %}", "{{ 'a }}", '{{ "\\q" }}',
        "{{ a if b else c }}", "{{ {} }}", "{{ a[1:2] }}", "{{ 1 +}}", "{{ x is foo }}",
        "{{ x|}}", "{% set a, b = 1 %}", "{% for a, b in x %}{% endfor %}",
        "{% for x in y if z %}{% endfor %}", "{% include 'a' ignore missing %}",
        "{% block a scoped %}{% endblock %}", "{% block a %}{% endblock b %}",
        "{% block a %}{% endblock %}{% block a %}{% endblock %}",
        "{% if true %}{% extends 'a' %}{% endif %}", "{% extends 'a' %}{% extends 'b' %}",
        "{% macro f(a, a) %}{% endmacro %}", "{% set true = 1 %}", "{% for and in x %}{% endfor %}",
        "{{ f(a=1, 2) }}", "{{ f(a=1, a=2) }}", "{{ x|f(a=1) }}", "{% if 1 %}{% else %}{% else %}{% endif %}",
        "{% if 1 %}{% else %}{% elif 2 %}{% endif %}", "{{ [1,] }}", "{{ 1 2 }}", "{{ x.0 }}",
    ],
)
def test_syntax_errors(source):
    with pytest.raises(TemplateSyntaxError):
        render(source)


# -- expressions ----------------------------------------------------------------

@pytest.mark.parametrize(
    "expr, expected",
    [
        ("1 + 2 * 3", "7"),
        ("-2 ** 2", "4"),
        ("2 ** 3 ** 2", "64"),
        ("2 ** -1", "0.5"),
        ("7 / 2", "3.5"),
        ("6 / 3", "2.0"),
        ("-7 // 2", "-4"),
        ("7.0 // 2", "3.0"),
        ("-7 % 3", "2"),
        ("7 % -3", "-2"),
        ("1 + 2.5", "3.5"),
        ("0.1 + 0.2", "0.30000000000000004"),
        ("1000000000000000.0 * 10", "1e+16"),
        ("0.00001 * 1", "1e-05"),
        ("0.0001 * 1", "0.0001"),
        ("'a' ~ 1 ~ true ~ none ~ 1.5", "a1TrueNone1.5"),
        ("2 * 3 ~ 4", "64"),
        ("'ab' * 3", "ababab"),
        ("3 * 'ab'", "ababab"),
        ("'ab' * -1", ""),
        ("[1] + [2, 3]", "[1, 2, 3]"),
        ("'a' + 'b'", "ab"),
        ("true + true", "2"),
        ("true == 1", "True"),
        ("1 == 1.0", "True"),
        ("1 == '1'", "False"),
        ("none == 0", "False"),
        ("none == none", "True"),
        ("[1, [2]] == [1, [2]]", "True"),
        ("1 < 2 < 3", "True"),
        ("3 > 2 > 2", "False"),
        ("'a' < 'b'", "True"),
        ("'ab' > 'a'", "True"),
        ("'b' in 'abc'", "True"),
        ("'' in 'abc'", "True"),
        ("2 in [1, 2]", "True"),
        ("2 not in [1, 2]", "False"),
        ("'k' in d", "True"),
        ("1 in d", "False"),
        ("0 or 'x'", "x"),
        ("'' and 1", ""),
        ("1 and 2", "2"),
        ("not 1 == 2", "True"),
        ("not 0", "True"),
        ("1 + x is defined", "2"),
        ("y is not defined", "True"),
        ("x is not defined", "False"),
        ("[1, 'a', true, none, 1.5, \"it's\", d]", "[1, 'a', True, None, 1.5, \"it's\", {'k': [2.0]}]"),
        ("'a\\nb\\t\\\\' | length", "5"),
        ("-x|int", "-1"),
        ("2 * x|int", "2"),
        ("d.k[0]", "2.0"),
        ("d['k'][-1]", "2.0"),
        ("'hello'[1]", "e"),
        ("'hello'[-1]", "o"),
        ("[1, 2][5] is defined", "False"),
        ("[1, 2][true]", "2"),
        ("d.nope is defined", "False"),
        ("range(3)|join(',')", "0,1,2"),
        ("range(1, 7, 2)|join(',')", "1,3,5"),
        ("range(3, 0, -1)|join(',')", "3,2,1"),
        ("range(0)|length", "0"),
    ],
)
def test_expression(expr, expected):
    context = {"x": 1, "d": {"k": [2.0]}}
    assert render("{{ " + expr + " }}", context) == expected


def test_comparison_chain_short_circuits():
    # The second comparison would be an undefined error if it were evaluated.
    assert render("{{ 2 < 1 < nope }}") == "False"
    assert render("{{ 0 and nope }}") == "0"
    assert render("{{ 1 or nope }}") == "1"


def test_undefined_attribute_results_and_default():
    assert render("{{ d.missing|default('dflt') }}", {"d": {}}) == "dflt"
    assert render("{{ none.x is defined }}") == "False"
    assert render("{{ (5).x is defined }}") == "False"


@pytest.mark.parametrize(
    "source",
    [
        "{{ nope }}", "{{ nope.x }}", "{{ nope|upper }}", "{{ nope == 1 }}", "{{ 1 + nope }}",
        "{% if nope %}{% endif %}", "{% for i in nope %}{% endfor %}", "{{ nope() }}", "{{ 1 in nope }}",
        "{{ [1][nope] }}", "{{ loop }}", "{{ super() }}", "{{ x|first|upper }}", "{{ nope|upper(1) }}",
        "{% include nope %}", "{{ 'a' ~ nope }}", "{{ not nope }}", "{{ -nope }}",
    ],
)
def test_undefined_errors(source):
    with pytest.raises(UndefinedError):
        render(source, {"x": []})


@pytest.mark.parametrize(
    "source",
    [
        "{{ 1 + 'a' }}", "{{ 'a' - 'b' }}", "{{ [1] * 2 }}", "{{ 1 / 0 }}", "{{ 1 // 0 }}", "{{ 1 % 0 }}",
        "{{ 0 ** -1 }}", "{{ 1 < 'a' }}", "{{ [1] < [2] }}", "{{ 1 in 5 }}", "{{ 1 in 'abc' }}", "{{ -'a' }}",
        "{{ 5() }}", "{{ 'a'() }}", "{% for i in 5 %}{% endfor %}", "{% for i in none %}{% endfor %}",
        "{{ 5|length }}", "{{ 'a'|upper(1) }}", "{{ 'a'|replace('a') }}", "{{ 'a'|default(1, 2) }}",
        "{{ range() }}", "{{ range(1, 2, 3, 4) }}", "{{ range(1.5) }}", "{{ range(0, 1, 0) }}", "{{ range(a=1) }}",
        "{{ [1, 'a']|sort }}", "{{ 5|join }}", "{{ 5|first }}", "{{ 5|reverse }}",
        "{% block a %}{{ super(1) }}{% endblock %}",
        "{% macro m(a) %}{% endmacro %}{{ m(1, 2) }}", "{% macro m(a) %}{% endmacro %}{{ m(b=1) }}",
        "{% macro m(a) %}{% endmacro %}{{ m(1, a=2) }}", "{% include 5 %}", "{% extends 5 %}",
    ],
)
def test_type_errors(source):
    with pytest.raises(TemplateTypeError):
        render(source)


def test_filter_and_template_errors():
    with pytest.raises(FilterError):
        render("{% if false %}{{ x|nosuch }}{% endif %}")
    with pytest.raises(TemplateNotFound):
        render("{% include 'missing' %}")
    with pytest.raises(TemplateNotFound):
        render("{% extends 'missing' %}")


def test_syntax_error_wins_over_filter_error():
    with pytest.raises(TemplateSyntaxError):
        render("{{ x|nosuch }}{% if %}")


def test_error_in_argument_wins_over_bad_callee():
    with pytest.raises(UndefinedError):
        render("{{ 5(nope.x) }}")
    with pytest.raises(TemplateTypeError):
        render("{{ nope(1 + 'a') }}")
    # a bare undefined name is only an error when it is used
    with pytest.raises(TemplateTypeError):
        render("{{ 5(nope) }}")


# -- filters -----------------------------------------------------------------------

@pytest.mark.parametrize(
    "expr, expected",
    [
        ("'Hello'|upper", "HELLO"),
        ("'Hello'|lower", "hello"),
        ("12|upper", "12"),
        ("true|lower", "true"),
        ("'  a b \\t\\n'|trim", "a b"),
        ("'<a href=\"x\">&\\'</a>'|escape", "&lt;a href=&#34;x&#34;&gt;&amp;&#39;&lt;/a&gt;"),
        ("'a-b-c'|replace('-', '+')", "a+b+c"),
        ("'aaa'|replace('aa', 'b')", "ba"),
        ("123|replace(2, 9)", "193"),
        ("'héllo'|length", "5"),
        ("[1, 2, 3]|length", "3"),
        ("d|length", "2"),
        ("'12'|int", "12"),
        ("' -7 '|int", "-7"),
        ("'+5'|int", "5"),
        ("'3.9'|int", "3"),
        ("'-3.9'|int", "-3"),
        ("'.5e1'|int", "5"),
        ("'1e2'|int", "100"),
        ("'abc'|int", "0"),
        ("''|int", "0"),
        ("-3.9|int", "-3"),
        ("true|int", "1"),
        ("none|int", "0"),
        ("[1]|int", "0"),
        ("[1, 2, 3]|join", "123"),
        ("[1, 'a', none]|join(', ')", "1, a, None"),
        ("d|join('/')", "k/j"),
        ("'abc'|join('-')", "a-b-c"),
        ("[1, 2]|first", "1"),
        ("[1, 2]|last", "2"),
        ("'abc'|first", "a"),
        ("d|first", "k"),
        ("[]|first is defined", "False"),
        ("[]|last is defined", "False"),
        ("'abc'|reverse", "cba"),
        ("[1, 2, 3]|reverse|join(',')", "3,2,1"),
        ("d|reverse|join(',')", "j,k"),
        ("[3, 1.5, 2, true]|sort|join(',')", "True,1.5,2,3"),
        ("['b', 'a', 'C']|sort|join('')", "abC"),
        ("[]|sort|length", "0"),
        ("nope|default", ""),
        ("nope|default('x')", "x"),
        ("0|default('x')", "0"),
        ("'a'|upper|lower|upper", "A"),
    ],
)
def test_filter(expr, expected):
    assert render("{{ " + expr + " }}", {"d": {"k": 1, "j": 2}}) == expected


def test_sort_is_stable_on_ascii_lowercase_key():
    assert render("{{ ['b', 'B', 'a', 'A']|sort|join('') }}") == "aAbB"


def test_filter_is_checked_even_in_unexecuted_macro_body():
    with pytest.raises(FilterError):
        render("{% macro m() %}{{ 1|nosuch }}{% endmacro %}ok")


# -- statements ----------------------------------------------------------------------

def test_if_elif_else():
    source = "{% if a %}A{% elif b %}B{% elif c %}C{% else %}D{% endif %}"
    assert render(source, {"a": 0, "b": 0, "c": 1}) == "C"
    assert render(source, {"a": 0, "b": 0, "c": 0}) == "D"
    assert render(source, {"a": "x", "b": 1, "c": 1}) == "A"


def test_truthiness_table():
    values = {"e": "", "z": 0, "f": 0.0, "n": None, "l": [], "d": {}, "t": False, "s": "0", "m": [0], "o": 2}
    source = "".join("{% if " + k + " %}1{% else %}0{% endif %}" for k in values)
    assert render(source, values) == "0000000" + "111"


def test_for_loop_variables_and_else():
    source = "{% for x in xs %}{{ loop.index }}/{{ loop.index0 }}/{{ loop.length }}/{{ loop.first }}/{{ loop.last }}:{{ x }};{% else %}empty{% endfor %}"
    assert render(source, {"xs": ["a", "b"]}) == "1/0/2/True/False:a;2/1/2/False/True:b;"
    assert render(source, {"xs": []}) == "empty"
    assert render("{% for c in 'ab' %}{{ c }}{% endfor %}") == "ab"
    assert render("{% for k in d %}{{ k }}{% endfor %}", {"d": {"z": 1, "a": 2}}) == "za"


def test_loop_is_not_defined_in_else_or_outside():
    with pytest.raises(UndefinedError):
        render("{% for x in [] %}{% else %}{{ loop.index }}{% endfor %}")


def test_nested_loops_use_the_innermost_loop():
    source = "{% for a in [1, 2] %}{% for b in [1, 2, 3] %}{{ loop.length }}{% endfor %}{{ loop.length }}{% endfor %}"
    assert render(source) == "3332" + "3332"


def test_set_scoping():
    assert render("{% set a = 1 %}{{ a }}") == "1"
    # a set inside a loop body is local to the iteration
    assert render("{% for i in [1, 2] %}{% set a = i %}{{ a }}{% endfor %}{{ a is defined }}") == "12False"
    # shadowing inside a loop does not change the outer binding
    assert render("{% set a = 1 %}{% for i in [1] %}{% set a = 2 %}{{ a }}{% endfor %}{{ a }}") == "21"
    # if bodies do not create scopes
    assert render("{% if true %}{% set a = 5 %}{% endif %}{{ a }}") == "5"


def test_set_can_store_undefined():
    assert render("{% set a = [][0] %}{{ a is defined }}") == "False"


def test_macros():
    source = (
        "{% macro greet(name, punct='!') %}Hello {{ name }}{{ punct }}{% endmacro %}"
        "{{ greet('A') }} {{ greet('B', '?') }} {{ greet(punct='.', name='C') }}"
    )
    assert render(source) == "Hello A! Hello B? Hello C."


def test_macro_defaults_see_earlier_parameters_and_unsupplied_params_are_undefined():
    assert render("{% macro m(a, b=a ~ '!') %}{{ b }}{% endmacro %}{{ m('x') }}") == "x!"
    assert render("{% macro m(a) %}{{ a is defined }}{% endmacro %}{{ m() }}") == "False"
    with pytest.raises(UndefinedError):
        render("{% macro m(a) %}{{ a }}{% endmacro %}{{ m() }}")


def test_macro_scope_is_lexical_and_sees_later_sets():
    source = "{% set x = 1 %}{% macro m() %}{{ x }}{{ y }}{% endmacro %}{% set y = 2 %}{{ m() }}"
    assert render(source) == "12"
    with pytest.raises(UndefinedError):
        render("{% macro m() %}{{ i }}{% endmacro %}{% for i in [1] %}{{ m() }}{% endfor %}")


def test_recursive_macro():
    source = "{% macro f(n) %}{% if n <= 1 %}1{% else %}{{ n * f(n - 1)|int }}{% endif %}{% endmacro %}{{ f(10) }}"
    assert render(source) == "3628800"


def test_macro_output_ignores_surrounding_whitespace_control():
    assert render("{% macro m() %} x {% endmacro %}[{{ m() }}]") == "[ x ]"


def test_include_sees_includers_scope_but_does_not_leak():
    templates = {"inc": "{{ a }}{{ loopvar }}{% set leaked = 1 %}"}
    source = "{% set a = 'A' %}{% for loopvar in [1, 2] %}{% include 'inc' %}{% endfor %}{{ leaked is defined }}"
    assert render(source, **templates) == "A1A2False"


def test_include_with_computed_name():
    assert render("{% include 'x' ~ 'y' %}", xy="[{{ 1 }}]") == "[1]"


# -- inheritance ----------------------------------------------------------------------

def test_block_override_and_super_chain():
    templates = {
        "base": "[{% block a %}base{% endblock %}]",
        "mid": "{% extends 'base' %}{% block a %}mid<{{ super() }}>{% endblock %}",
        "leaf": "{% extends 'mid' %}{% block a %}leaf<{{ super() }}>{% endblock %}",
    }
    env = Environment(templates)
    assert env.render("base", {}) == "[base]"
    assert env.render("mid", {}) == "[mid<base>]"
    assert env.render("leaf", {}) == "[leaf<mid<base>>]"


def test_super_without_parent_block_is_undefined():
    with pytest.raises(UndefinedError):
        render("{% block a %}{{ super() }}{% endblock %}")


def test_child_output_outside_blocks_is_discarded_but_before_extends_is_kept():
    templates = {"base": "<{% block a %}x{% endblock %}>"}
    source = "pre{% extends 'base' %}junk{{ 1 }}{% block a %}y{% endblock %}more"
    assert render(source, **templates) == "pre<y>"


def test_child_blocks_not_in_parent_are_never_rendered():
    assert render("{% extends 'base' %}{% block other %}!{% endblock %}", base="b") == "b"


def test_set_and_macro_after_extends_are_visible_to_parent_and_blocks():
    templates = {
        "base": "{% block a %}{{ v }}{% endblock %}|{{ m(3) }}|{% macro inner() %}i{% endmacro %}",
    }
    source = "{% extends 'base' %}{% set v = 'V' %}{% macro m(n) %}M{{ n }}{{ inner is defined }}{% endmacro %}"
    assert render(source, **templates) == "V|M3False|"


def test_block_scope_does_not_see_loop_variables():
    source = "{% for i in [1] %}{% block b %}{{ i is defined }}{% endblock %}{% endfor %}"
    assert render(source) == "False"


def test_nested_blocks_and_block_in_included_template():
    templates = {
        "base": "{% block outer %}<{% block inner %}in{% endblock %}>{% endblock %}",
        "inc": "{% extends 'base' %}{% block inner %}INC{% endblock %}",
    }
    source = "{% extends 'base' %}{% block inner %}X{% endblock %}"
    assert render(source, **templates) == "<X>"
    assert render("a{% include 'inc' %}b", **templates) == "a<INC>b"


def test_unused_templates_are_never_parsed():
    env = Environment({"main": "ok", "broken": "{% if %}"})
    assert env.render("main", {}) == "ok"
    with pytest.raises(TemplateSyntaxError):
        env.render("broken", {})


def test_templates_are_parsed_once():
    env = Environment({"main": "{{ 1 }}"})
    assert env.get_template("main") is env.get_template("main")


def test_context_is_not_modified():
    context = {"a": 1}
    Environment({"main": "{% set b = 2 %}{{ a + b }}"}).render("main", context)
    assert context == {"a": 1}
