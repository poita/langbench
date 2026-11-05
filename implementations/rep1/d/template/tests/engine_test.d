module tests.engine_test;

import jtemplate;
import tests.support;

unittest // text, variables, expressions
{
    assert(render("plain") == "plain");
    assert(render("Hello {{ name }}!", `{"name": "Ada"}`) == "Hello Ada!");
    assert(render("{{ 1 + 2 * 3 }} {{ (1 + 2) * 3 }} {{ 7 / 2 }} {{ 7 // 2 }} {{ 7 % 3 }}") == "7 9 3.5 3 1");
    assert(render(`{{ a.b.c }} {{ l[1] }} {{ l[-1] }}`, `{"a":{"b":{"c":5}},"l":[1,2,3]}`) == "5 2 3");
    assert(render(`{{ [1, 'a', true, none, 1.5] }}`) == "[1, 'a', True, None, 1.5]");
}

unittest // and / or return operands
{
    assert(render(`{{ 0 or "x" }} {{ "" and 1 }}| {{ 1 and 2 }} {{ not 0 }}`) == "x | 2 True");
}

unittest // comparison chains short-circuit
{
    assert(render(`{{ 1 < 2 < 3 }} {{ 3 > 2 > 2 }} {{ 1 < 0 < nope }}`) == "True False False");
}

unittest // if / elif / else
{
    string t = `{% if n > 5 %}big{% elif n > 2 %}mid{% else %}small{% endif %}`;
    assert(render(t, `{"n": 9}`) == "big");
    assert(render(t, `{"n": 3}`) == "mid");
    assert(render(t, `{"n": 0}`) == "small");
}

unittest // for, loop, else
{
    assert(render(`{% for x in xs %}{{ loop.index }}/{{ loop.length }}:{{ x }}{% if not loop.last %},{% endif %}{% endfor %}`,
                  `{"xs": ["a","b","c"]}`) == "1/3:a,2/3:b,3/3:c");
    assert(render(`{% for x in [] %}x{% else %}empty{% endfor %}`) == "empty");
    assert(render(`{% for k in d %}{{ k }}={{ d[k] }} {% endfor %}`, `{"d": {"z": 1, "a": 2}}`) == "z=1 a=2 ");
    assert(render(`{% for c in "hé" %}[{{ c }}]{% endfor %}`) == "[h][é]");
    assert(render(`{% for i in range(3) %}{% for j in range(i) %}{{ loop.index }}{% endfor %}{% endfor %}`) == "112");
    assert(errorOf(`{{ loop }}`) == ErrorKind.undefined);
    assert(errorOf(`{% for x in 5 %}{% endfor %}`) == ErrorKind.type);
}

unittest // set is scoped
{
    assert(render(`{% set a = 1 %}{{ a }}{% for i in [1] %}{% set a = 2 %}{{ a }}{% endfor %}{{ a }}`) == "121");
    assert(render(`{% for i in [1,2] %}{% set t = i * 2 %}{{ t }}{% endfor %}{{ t is defined }}`) == "24False");
}

unittest // macros
{
    assert(render(`{% macro f(a, b=2) %}{{ a }}-{{ b }}{% endmacro %}{{ f(1) }} {{ f(1, 3) }} {{ f(b=5, a=0) }}`)
           == "1-2 1-3 0-5");
    assert(render(`{% macro fact(n) %}{% if n <= 1 %}1{% else %}{{ n * fact(n - 1)|int }}{% endif %}{% endmacro %}{{ fact(10) }}`)
           == "3628800");
    assert(render(`{% macro m(x) %}{{ x is defined }}{% endmacro %}{{ m() }}`) == "False");
    assert(errorOf(`{% macro m(a) %}{% endmacro %}{{ m(1, 2) }}`) == ErrorKind.type);
    assert(errorOf(`{% macro m(a) %}{% endmacro %}{{ m(z=1) }}`) == ErrorKind.type);
    assert(errorOf(`{% macro m(a) %}{% endmacro %}{{ m(1, a=1) }}`) == ErrorKind.type);
    assert(errorOf(`{% macro m(a) %}{{ a }}{% endmacro %}{{ m() }}`) == ErrorKind.undefined);
}

unittest // macros see their defining scope, not the caller's
{
    assert(render(`{% set g = "G" %}{% macro m() %}{{ g }}{{ l is defined }}{% endmacro %}{% for l in [1] %}{{ m() }}{% endfor %}`)
           == "GFalse");
}

unittest // include sees the includer's scope
{
    assert(render(`{% set v = "V" %}{% include "inc" %}[{{ w is defined }}]`, "{}",
                  ["inc": "<{{ v }}>{% set w = 1 %}"]) == "<V>[False]");
    assert(errorOf(`{% include "nope" %}`) == ErrorKind.missingTemplate);
    assert(errorOf(`{% include 3 %}`) == ErrorKind.type);
    assert(errorOf(`{% include nope %}`) == ErrorKind.undefined);
}

unittest // included templates are checked when loaded
{
    assert(errorOf(`{% include "bad" %}`, "{}", ["bad": "{% if %}"]) == ErrorKind.syntax);
    assert(errorOf(`{% include "bad" %}`, "{}", ["bad": "{{ 1|zzz }}"]) == ErrorKind.filter);
    // an unused broken template is never looked at
    assert(render("ok", "{}", ["bad": "{% if %}"]) == "ok");
}

unittest // inheritance, super and overrides
{
    string[string] t = [
        "base": "[{% block a %}A{% endblock %}|{% block b %}B{% endblock %}]",
        "mid":  `{% extends "base" %}{% block a %}<{{ super() }}>{% endblock %}`,
    ];
    assert(render(`{% extends "mid" %}{% block a %}({{ super() }}){% endblock %}{% block b %}b{% endblock %}`,
                  "{}", t) == "[(<A>)|b]");
}

unittest // after extends only blocks, set and macro matter
{
    string[string] t = ["base": "{% block body %}{% endblock %}!"];
    assert(render(`pre {% extends "base" %} ignored {% set x = 5 %}{% block body %}{{ x }}{% endblock %} ignored`,
                  "{}", t) == "pre 5!");
}

unittest // super without a parent block
{
    assert(errorOf(`{% block a %}{{ super() }}{% endblock %}`) == ErrorKind.undefined);
}

unittest // blocks do not see loop variables of the enclosing block
{
    assert(errorOf(`{% for i in [1] %}{% block a %}{{ i }}{% endblock %}{% endfor %}`) == ErrorKind.undefined);
}

unittest // whitespace control
{
    assert(render("a  {{- 1 -}}  b") == "a1b");
    assert(render("a\n{%- if true -%}\n  x\n{%- endif %}\nb") == "ax\nb");
    assert(render("a {# gone #} b") == "a  b");
}

unittest // the undefined value
{
    assert(render(`{{ nope is defined }}{{ nope is not defined }}{{ nope|default("d") }}`) == "FalseTrued");
    assert(errorOf(`{{ nope }}`) == ErrorKind.undefined);
    assert(errorOf(`{{ a.b.c }}`, `{"a": {}}`) == ErrorKind.undefined);
    assert(errorOf(`{% if nope %}{% endif %}`) == ErrorKind.undefined);
    assert(errorOf(`{{ nope == 1 }}`) == ErrorKind.undefined);
    assert(errorOf(`{{ nope() }}`) == ErrorKind.undefined);
}

unittest // range
{
    assert(render(`{{ range(3)|join(",") }} {{ range(2, 5)|join(",") }} {{ range(5, 0, -2)|join(",") }} {{ range(0)|length }}`)
           == "0,1,2 2,3,4 5,3,1 0");
    assert(errorOf(`{{ range(1, 2, 0) }}`) == ErrorKind.type);
    assert(errorOf(`{{ range("a") }}`) == ErrorKind.type);
    assert(errorOf(`{{ range() }}`) == ErrorKind.type);
}

unittest // errors anywhere discard all output
{
    auto e = new Engine;
    e.addTemplate("main", "before {{ nope }}");
    bool threw;
    try e.render("main", parseJson("{}"));
    catch (TemplateError err) threw = err.kind == ErrorKind.undefined;
    assert(threw);
}

unittest // the engine caches templates and can be re-used
{
    auto e = new Engine;
    e.addTemplate("main", "{{ x }}");
    assert(e.renderJson("main", `{"x": 1}`) == "1");
    assert(e.renderJson("main", `{"x": 2}`) == "2");
    assert(e.hasTemplate("main") && !e.hasTemplate("other"));
    e.addTemplate("main", "{{ x + 1 }}");
    assert(e.renderJson("main", `{"x": 1}`) == "2");
}
