/**
 * Conformance tests for the template engine.
 *
 * The expected outputs were produced by Jinja2 3.1 with `StrictUndefined`,
 * `trim_blocks=False`, `lstrip_blocks=False` and autoescape off.
 */
module sitegen.templating.conformance;

version (unittest)
{
    import sitegen.templating;

    private struct Case
    {
        /// The templates; the first is rendered.
        string[] templates;
        string expected;
    }

    private Value[string] context()
    {
        Value[string] c;
        c["items"] = Value.list([Value.integer(3), Value.integer(1), Value.integer(2)]);
        c["title"] = Value.str("T");
        auto a = new Dict;
        a.set("n", Value.str("a"));
        a.set("t", Value.list(["x", "y"]));
        auto b = new Dict;
        b.set("n", Value.str("b"));
        b.set("t", Value.list(cast(Value[])[]));
        c["users"] = Value.list([Value.dict(a), Value.dict(b)]);
        auto d = new Dict;
        d.set("k1", Value.integer(1));
        d.set("k2", Value.integer(2));
        c["d"] = Value.dict(d);
        c["s"] = Value.str("hello");
        c["n"] = Value.integer(0);
        return c;
    }

    private immutable Case[] cases = [
        Case(["{% for u in users %}{{ loop.index }}/{{ loop.length }}:{{ u.n }}{% for x in u.t %}[{{ loop.index0 }}{{ x }}{% if loop.last %}!{% endif %}]{% else %}(none){% endfor %};{% endfor %}"],
             "1/2:a[0x][1y!];2/2:b(none);"),
        Case(["{% for k in d %}{{ k }}={{ d[k] }},{% endfor %}{% for c in s %}{{ c }}-{% endfor %}"],
             "k1=1,k2=2,h-e-l-l-o-"),
        Case(["{% set a = 1 %}{% for i in items %}{% set a = i %}{{ a }}{% endfor %}{{ a }}"],
             "3121"),
        Case(["{% set x = 5 %}{% macro m(a, b=x) %}{{ a }}-{{ b }}-{{ x }}{% endmacro %}{% set x = 6 %}{{ m(1) }} {{ m(1, 2) }} {{ m(b=3, a=4) }}"],
             "1-6-6 1-2-6 4-3-6"),
        Case(["{% macro f(n) %}{% if n <= 1 %}1{% else %}{{ n * f(n-1)|int }}{% endif %}{% endmacro %}{{ f(6) }}"],
             "720"),
        Case(["{% macro m(a, b) %}{{ a }}{{ b is defined }}{% endmacro %}{{ m(1) }}"],
             "1False"),
        Case(["{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, 2) }}"],
             "error: type"),
        Case(["{% macro m(a) %}{{ a }}{% endmacro %}{{ m(b=2) }}"],
             "error: type"),
        Case(["{% macro m(a) %}{{ a }}{% endmacro %}{{ m(1, a=2) }}"],
             "error: type"),
        Case(["{% extends \"b\" %}{% block x %}child {{ super() }}{% endblock %}", "[{% block x %}base{% endblock %}]"],
             "[child base]"),
        Case(["{% extends \"b\" %}{% block x %}C{{ super() }}{% endblock %}", "{% extends \"c\" %}{% block x %}B{{ super() }}{% endblock %}", "<{% block x %}A{% endblock %}>"],
             "<CBA>"),
        Case(["pre {% extends \"b\" %} ignored {{ 1/0 }} {% set y = 3 %}{% block x %}{{ y }}{% endblock %}", "[{% block x %}base{% endblock %}] {{ y }}"],
             "pre [3] 3"),
        Case(["{% extends \"b\" %}{% macro mm() %}M{% endmacro %}{% block x %}{{ mm() }}{% endblock %}", "[{% block x %}{% endblock %}]"],
             "[M]"),
        Case(["{% extends \"b\" %}{% block x %}{% for i in items %}{{ i }}{% endfor %}{{ i }}{% endblock %}", "[{% block x %}{% endblock %}]"],
             "error: undefined"),
        Case(["{% for i in items %}{% block x %}{{ i }}{% endblock %}{% endfor %}"],
             "error: undefined"),
        Case(["{% include \"b\" %}|{% set q = 1 %}{% include \"c\" %}", "inc {{ title }} {% set z = 2 %}{{ z }}", "{{ q }}{{ z }}"],
             "error: undefined"),
        Case(["{% for i in items %}{% include \"b\" %}{% endfor %}", "<{{ i }}>"],
             "<3><1><2>"),
        Case(["{% include \"nope\" %}"],
             "error: template"),
        Case(["{% extends \"nope\" %}"],
             "error: template"),
        Case(["{% include s %}", "x"],
             "error: template"),
        Case(["{% include 3 %}"],
             "error: type"),
        Case(["{% include undefined_thing %}"],
             "error: undefined"),
        Case(["A  {%- if 1 -%}  B  {%- endif -%}   C  {# c #}  D {#- c -#}   E\n  {%- set a = 1 %}\n{{ a }}"],
             "ABC    DE\n1"),
        Case(["x {{- \"a\" -}} y {{ \"b\" }} {{- \"c\" }}"],
             "xay bc"),
        Case(["{% block a %}1{% block b %}2{% endblock %}3{% endblock %}"],
             "123"),
        Case(["{% extends \"b\" %}{% block a %}[{{ super() }}]{% block b %}<{{ super() }}>{% endblock %}{% endblock %}", "{% block a %}1{% block b %}2{% endblock %}3{% endblock %}"],
             "[1<2>3]<2>"),
        Case(["{{ super() }}"],
             "error: undefined"),
        Case(["{% block a %}{{ super() }}{% endblock %}"],
             "error: undefined"),
        Case(["{% macro m() %}{% block z %}Z{% endblock %}{% endmacro %}{{ m() }}"],
             "Z"),
        Case(["{% set s2 = items|sort|reverse|join(\",\") %}{{ s2 }} {{ items|sort|first }} {{ items|last }} {{ \"a,b\"|replace(\",\", \";\") }} {{ items|length }}"],
             "3,2,1 1 2 a;b 3"),
        Case(["{{ 5 // 2 }} {{ -5 // 2 }} {{ 5 % -3 }} {{ 2 ** 10 }} {{ 7 / 2 }} {{ 1.0 * 3 }} {{ 10 / 4 }} "],
             "2 -3 -1 1024 3.5 3.0 2.5 "),
        Case(["{{ 'a' ~ 1 ~ true ~ none ~ 2.0 }} {{ [1,'a',none] }} {{ d }} {{ 0.1 + 0.2 }} {{ 10.0 ** 22 }}"],
             "a1TrueNone2.0 [1, 'a', None] {'k1': 1, 'k2': 2} 0.30000000000000004 1e+22"),
        Case(["{{ 100000000000000000.0 }} {{ 1.0 / 10000000 }} {{ 123456789012345678 }} {{ 0.00001234 }} {{ 1/3 }} {{ 2/3 }} {{ 5.0 }}"],
             "1e+17 1e-07 123456789012345678 1.234e-05 0.3333333333333333 0.6666666666666666 5.0"),
        Case(["{% if n %}a{% elif s %}b{% else %}c{% endif %}{% if items %}y{% endif %}{% if [] %}n{% else %}e{% endif %}"],
             "bye"),
        Case(["{{ n and 1 }}{{ n or 'z' }}{{ s and 'q' }}{{ not n }}"],
             "0zqTrue"),
        Case(["{{ 1 < 2 < 3 }}{{ 3 > 2 > 2 }}{{ 1 == 1.0 }}{{ 'a' < 'b' }}{{ 'a' in s }}{{ 'h' in s }}{{ 1 in items }}{{ 'k1' in d }}{{ 5 not in items }}"],
             "TrueFalseTrueTrueFalseTrueTrueTrueTrue"),
        Case(["{{ undefinedvar }}"],
             "error: undefined"),
        Case(["{{ undefinedvar|default('d') }}{{ undefinedvar is defined }}{{ s is defined }}{{ d.zz is not defined }}{{ undefinedvar.x }}"],
             "error: undefined"),
        Case(["{% set u = d.zz %}{{ u is defined }}{{ u|default(7) }}"],
             "False7"),
        Case(["{% for i in items %}{{ i }}{% endfor %}{{ loop }}"],
             "error: undefined"),
        Case(["{% for i in 5 %}{% endfor %}"],
             "error: type"),
        Case(["{{ s[0] }}{{ s[-1] }}{{ s[9] is defined }}{{ items[1] }}{{ items[-3] }}{{ d['k2'] }}{{ items['a'] is defined }}"],
             "hoFalse132False"),
        Case(["{{ ' x '|trim }}{{ 'AbC'|lower }}"],
             "xabc"),
        Case(["{{ '1.5'|int }} {{ ' 12 '|int }} {{ 'x'|int }} {{ 3.9|int }} {{ -3.9|int }} {{ true|int }} {{ none|int }}"],
             "1 12 0 3 -3 1 0"),
        Case(["{{ [3,1,2]|sort }} {{ ['b','A','a','B']|sort }} {{ 'abc'|reverse }} {{ items|reverse|join }}"],
             "[1, 2, 3] ['A', 'a', 'b', 'B'] cba 213"),
        Case(["{{ range(5)|join(',') }} {{ range(1,10,3)|join(',') }} {{ range(5,0,-2)|join(',') }} {{ range(0)|first }}"],
             "error: undefined"),
        Case(["{{ range(0)|first is defined }}"],
             "False"),
        Case(["{{ 'a<b>&\"\\'' |escape }}"],
             "a&lt;b&gt;&amp;&#34;&#39;"),
        Case(["{% set a = 1 %}{% macro m() %}{{ a }}{% endmacro %}{% set a = 2 %}{{ m() }}"],
             "2"),
        Case(["{% macro m() %}{{ n }}{% endmacro %}{% for n in items %}{{ m() }}{% endfor %}"],
             "000"),
        Case(["{% macro outer() %}{% macro inner() %}I{% endmacro %}{{ inner() }}{% endmacro %}{{ outer() }}"],
             "I"),
        Case(["{% for i in items %}{% set last = i %}{% endfor %}{{ last }}"],
             "error: undefined"),
        Case(["{% if s %}{% set q = 1 %}{% endif %}{{ q }}"],
             "1"),
        Case(["{{ items|sort|join }}|{{ d|join('-') }}|{{ s|join('.') }}|{{ items|first }}"],
             "123|k1-k2|h.e.l.l.o|3"),
        Case(["{% extends \"b\" %}{% set v = \"V\" %}{% block x %}{{ v }}{% endblock %}", "{{ v }}[{% block x %}{% endblock %}]"],
             "V[V]"),
        Case(["{% include \"b\" %}", "{% extends \"c\" %}{% block x %}b{% endblock %}", "<{% block x %}c{% endblock %}>"],
             "<b>"),
        Case(["{% macro m(a, b=[1,2]) %}{{ b|length }}{{ a }}{% endmacro %}{{ m(0) }}{{ m(0, 'abc') }}"],
             "2030"),
        Case(["{{ x }}{% set x = 1 %}"],
             "error: undefined"),
        Case(["{% for i in items %}{{ i }}{% if not loop.last %},{% endif %}{% endfor %}"],
             "3,1,2"),
        Case(["{% for i in items %}{% for j in items %}{{ loop.index }}{% endfor %}{{ loop.index }}{% endfor %}"],
             "123112321233"),
        Case(["{{ 'a' * 3 }}{{ 3 * 'b' }}{{ -1 * 'c' }}{{ [1] + [2] }}{{ 'a' + 'b' }}"],
             "aaabbb[1, 2]ab"),
        Case(["{{ 2 ** 3 ** 2 }} {{ -2 ** 2 }} {{ (-2) ** 2 }} {{ 2 ** -1 }} {{ -n }}"],
             "64 4 4 0.5 0"),
        Case(["{{ 1 + 2 * 3 - 4 / 2 }} {{ 7 % 3 * 2 }} {{ 1 ~ 2 + 3 }}"],
             "error: type"),
        Case(["{{ not 1 == 2 }} {{ 1 + 1 == 2 and 2 * 2 == 4 }} {{ 'x' in 'xyz' and 'q' not in 'xyz' }}"],
             "True True True"),
    ];

    unittest
    {
        foreach (idx, c; cases)
        {
            auto engine = new TemplateEngine;
            foreach (i, t; c.templates)
                engine.addTemplate(i == 0 ? "main" : ["b", "c", "d", "e"][i - 1], t);
            string got;
            try
                got = engine.render("main", context());
            catch (TemplateException e)
                got = "error: " ~ ["syntax", "filter", "undefined", "template", "type"][e.kind];
            import std.conv : to;

            assert(got == c.expected, "case " ~ idx.to!string ~ ": got " ~ got ~ " expected " ~ c.expected);
        }
    }
}
