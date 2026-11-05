/// Unit tests for the template engine.
module tests.templating_test;

import sitegen.templating;
import std.algorithm.searching : startsWith;

private DictObj dictOf(string[] keys, Value[] values)
{
    auto d = new DictObj;
    foreach (i, k; keys)
        d.set(k, values[i]);
    return d;
}

/// Render `templates[0]` with the given root bindings; returns the output, or
/// `error: <kind>` on failure (the format of the template problem).
private string run(string[string] templates, string entry, Value[string] ctx = null)
{
    auto engine = new Engine((string name, out string src) {
        if (auto p = name in templates)
        {
            src = *p;
            return true;
        }
        return false;
    });
    auto root = new Scope;
    foreach (k, v; ctx)
        root.set(k, v);
    try
        return engine.render(entry, root);
    catch (TemplateError e)
        return "error: " ~ TemplateError.kindName(e.kind);
}

private string one(string tpl, Value[string] ctx = null)
{
    return run(["main": tpl], "main", ctx);
}

unittest // text, print and comments
{
    assert(one("plain") == "plain");
    assert(one("a{# hidden #}b") == "ab");
    assert(one("{{ 1 + 2 }}") == "3");
    assert(one("{{{ x }}}") == "error: syntax");
    assert(one("{{ 1 ") == "error: syntax");
    assert(one("{# open") == "error: syntax");
}

unittest // whitespace control
{
    assert(one("a  \n {{- 1 -}}  \n b") == "a1b");
    assert(one("a {%- if true -%} b {%- endif -%} c") == "abc");
    assert(one("x {#- c -#} y") == "xy");
    assert(one("{{ 1 }} \n {{ 2 }}") == "1 \n 2");
    assert(one("{{ 5 -}}") == "5");
}

unittest // literals, operators and printing
{
    assert(one("{{ 7 / 2 }} {{ 7 // 2 }} {{ -7 // 2 }} {{ 7 % 3 }} {{ -7 % 3 }} {{ 7 % -3 }}") == "3.5 3 -4 1 2 -2");
    assert(one("{{ 2 ** 10 }} {{ -2 ** 2 }} {{ 2 ** -1 }}") == "1024 4 0.5");
    assert(one("{{ 'a' ~ 1 ~ true }}") == "a1True");
    assert(one("{{ 'ab' * 3 }}") == "ababab");
    assert(one("{{ 0.1 + 0.2 }} {{ 3 * 1.0 }}") == "0.30000000000000004 3.0");
    assert(one("{{ [1, 'a', true, none, 1.5, \"it's\"] }}") == "[1, 'a', True, None, 1.5, \"it's\"]");
    assert(one("{{ 0 or 'x' }} {{ '' and 1 }}|{{ 1 and 2 }} {{ not 1 == 2 }}") == "x |2 True");
    assert(one("{{ 1 < 2 < 3 }} {{ 1 < 3 < 2 }} {{ 1 == 1.0 }} {{ true == 1 }}") == "True False True True");
    assert(one("{{ 'b' in 'abc' }} {{ 3 not in [1, 2] }} {{ 'k' in x }}", ["x": Value.of(dictOf(["k"], [Value.of(1)]))]) == "True True True");
}

unittest // variables, attributes and subscripts
{
    auto user = dictOf(["name", "tags"], [Value.of("Ada"), Value.of([Value.of("x"), Value.of("y")])]);
    Value[string] ctx = ["user": Value.of(user)];
    assert(one("{{ user.name }} {{ user.tags[1] }} {{ user.tags[-1] }} {{ user['name'][0] }}", ctx) == "Ada y y A");
    assert(one("{{ user.missing }}", ctx) == "error: undefined");
    assert(one("{{ user.missing is defined }} {{ user.name is not defined }}", ctx) == "False False");
    assert(one("{{ user.missing|default('none') }}", ctx) == "none");
    assert(one("{{ user.missing.deeper }}", ctx) == "error: undefined");
    assert(one("{{ nothing }}") == "error: undefined");
}

unittest // statements
{
    auto xs = Value.of([Value.of(3), Value.of(1), Value.of(2)]);
    Value[string] ctx = ["xs": xs];
    assert(one("{% for x in xs %}{{ loop.index }}:{{ x }}{% if not loop.last %},{% endif %}{% endfor %}", ctx) == "1:3,2:1,3:2");
    assert(one("{% for x in [] %}a{% else %}empty{% endfor %}") == "empty");
    assert(one("{% set n = 5 %}{% if n > 9 %}big{% elif n > 3 %}mid{% else %}small{% endif %}") == "mid");
    assert(one("{% for i in range(3) %}{{ i }}{% endfor %}{{ range(1, 6, 2)|join('-') }}") == "012" ~ "1-3-5");
    assert(one("{% for c in 'héé' %}[{{ c }}]{% endfor %}") == "[h][é][é]");
    assert(one("{% for x in xs %}{% set y = x * 2 %}{{ y }}{% endfor %}{{ y is defined }}", ctx) == "624False");
    assert(one("{% for x in xs %}{% endfor %}{% set z = 1 %}{{ z }}", ctx) == "1");
}

unittest // macros
{
    assert(one("{% macro m(a, b=2) %}{{ a }}{{ b }}{% endmacro %}{{ m(1) }}{{ m(1, 3) }}{{ m(b=9, a=0) }}") == "121309");
    assert(one("{% macro f(n) %}{% if n < 2 %}1{% else %}{{ n * f(n - 1)|int }}{% endif %}{% endmacro %}{{ f(5) }}") == "120");
    assert(one("{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, 2) }}") == "error: type");
    assert(one("{% macro m(a) %}{{ a }}{% endmacro %}{{ m() }}") == "error: undefined");
    assert(one("{% macro m(a) %}{{ a }}{% endmacro %}{{ m(c=1) }}") == "error: type");
}

unittest // filters
{
    assert(one("{{ 'aBc'|upper }}{{ 'aBc'|lower }}[{{ '  x '|trim }}]") == "ABCabc[x]");
    assert(one("{{ '<a href=\"x\">&\\'</a>'|escape }}") == "&lt;a href=&#34;x&#34;&gt;&amp;&#39;&lt;/a&gt;");
    assert(one("{{ 'aXbXc'|replace('X', '--') }}") == "a--b--c");
    assert(one("{{ 'héé'|length }} {{ [1, 2]|length }} {{ 5|length }}") == "error: type");
    assert(one("{{ 'héé'|length }} {{ [1, 2]|length }}") == "3 2");
    assert(one("{{ '12'|int + 1 }} {{ ' -3.9 '|int }} {{ 'abc'|int }} {{ 2.7|int }} {{ true|int }}") == "13 -3 0 2 1");
    assert(one("{{ [3, 1, 2]|sort|join(',') }} {{ ['b', 'A', 'c']|sort|join }} {{ [1, 2, 3]|reverse|join('') }}") == "1,2,3 Abc 321");
    assert(one("{{ 'abc'|reverse }} {{ [1, 2]|first }} {{ [1, 2]|last }} {{ []|first is defined }}") == "cba 1 2 False");
    assert(one("{{ x|default('d') }}{{ 0|default('d') }}") == "d0");
    assert(one("{{ 1|nope }}") == "error: filter");
    assert(one("{{ 1|nope }}{% if %}") == "error: syntax");
    assert(one("{{ x|upper }}") == "error: undefined");
    assert(one("{{ 'a'|upper(1) }}") == "error: type");
}

unittest // include
{
    string[string] t = ["main": "[{% include 'part' %}]{{ inner is defined }}", "part": "{% set inner = 1 %}{{ outer }}"];
    assert(run(t, "main", ["outer": Value.of("o")]) == "[o]False");
    assert(run(["main": "{% include 'nope' %}"], "main") == "error: template");
    assert(run(["main": "{% include 3 %}"], "main") == "error: type");
}

unittest // inheritance
{
    string[string] t = [
        "page": "{% extends 'base' %}\n{% set count = items|length %}\n{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}",
        "base": "{% macro item(v) %}#{{ v }}{% endmacro -%}\n<h1>{% block title %}{{ title }}{% endblock %}</h1>\n{% block body %}{{ count }} items{% endblock %}\n{% include 'footer' %}",
        "footer": "-- {{ title|lower }} {{ missing|default('end') }}",
    ];
    auto items = Value.of([Value.of(3), Value.of(1), Value.of(2)]);
    assert(run(t, "page", ["title": Value.of("T"), "items": items])
            == "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end");
    // three levels
    string[string] t3 = [
        "c": "{% extends 'b' %}{% block x %}C({{ super() }}){% endblock %}",
        "b": "{% extends 'a' %}{% block x %}B({{ super() }}){% endblock %}",
        "a": "{% block x %}A{% endblock %}",
    ];
    assert(run(t3, "c") == "C(B(A))");
    assert(run(["m": "{% block x %}{{ super() }}{% endblock %}"], "m") == "error: undefined");
}

unittest // syntax errors
{
    foreach (bad; ["{% if true %}", "{% endif %}", "{% for a, b in x %}{% endfor %}", "{% raw %}",
            "{% block a %}{% endblock %}{% block a %}{% endblock %}", "{% if true %}{% extends 'x' %}{% endif %}",
            "{{ 1 if true }}", "{{ x is odd }}", "{{ 'bad \\q' }}", "{{ f(a=1, 2) }}", "{% set a, b = 1 %}",
            "{% block a %}{% endblock b %}", "{{ - }}", "{{ x - }}", "{% include 'a' ignore missing %}"])
        assert(one(bad) == "error: syntax", bad);
}

unittest // float formatting
{
    assert(formatFloat(1e16) == "1e+16");
    assert(formatFloat(1e-5) == "1e-05");
    assert(formatFloat(1.5e300) == "1.5e+300");
    assert(formatFloat(1000000000000000.0) == "1000000000000000.0");
    assert(formatFloat(0.0001) == "0.0001");
    assert(formatFloat(-0.0) == "-0.0");
}
