//! End-to-end tests of the library: render a template against a context and
//! check the output or the error kind.

use template::{render_input, ErrorKind};

/// Renders `main` (plus extra `(name, body)` templates) against a JSON context.
fn render_with(ctx: &str, main: &str, others: &[(&str, &str)]) -> Result<String, ErrorKind> {
    let mut input = format!("{ctx}\n--\n=== main\n{main}");
    for (name, body) in others {
        input.push_str(&format!("\n=== {name}\n{body}"));
    }
    render_input(&input).map_err(|e| e.kind())
}

fn render(main: &str) -> Result<String, ErrorKind> {
    render_with("{}", main, &[])
}

fn ok(main: &str) -> String {
    render(main).unwrap_or_else(|k| panic!("unexpected error: {k}"))
}

fn err(main: &str) -> ErrorKind {
    render(main).expect_err("expected an error")
}

#[test]
fn text_and_braces() {
    assert_eq!(ok("plain { } } text {x"), "plain { } } text {x");
    assert_eq!(ok(""), "");
}

#[test]
fn expressions_and_precedence() {
    assert_eq!(ok("{{ 1 + 2 * 3 }}"), "7");
    assert_eq!(ok("{{ -2 ** 2 }}"), "4");
    assert_eq!(ok("{{ 2 ** -1 }}"), "0.5");
    assert_eq!(ok("{{ 7 / 2 }} {{ 7 // 2 }} {{ -7 // 2 }} {{ -7 % 3 }} {{ 7 % -3 }}"), "3.5 3 -4 2 -2");
    assert_eq!(ok("{{ 7.0 // 2 }} {{ 6 / 3 }}"), "3.0 2.0");
    assert_eq!(ok("{{ 'a' ~ 1 ~ none ~ true }}"), "a1NoneTrue");
    assert_eq!(ok("{{ 'ab' * 2 }}{{ 3 * 'x' }}[{{ 'x' * -1 }}]"), "ababxxx[]");
    assert_eq!(ok("{{ true + true }} {{ true == 1 }}"), "2 True");
    assert_eq!(ok("{{ 0 or 'x' }} {{ '' and 1 }}| {{ 1 and 2 }} {{ not 0 }}"), "x | 2 True");
    assert_eq!(ok("{{ 1 < 2 < 3 }} {{ 3 > 2 > 2 }} {{ 1 == 1.0 }}"), "True False True");
    assert_eq!(ok("{{ 2 ** 3 ** 2 }}"), "64");
    assert_eq!(ok("{{ 'b' in 'abc' }} {{ 3 not in [1, 2] }} {{ 'k' in 'abc' }}"), "True True False");
}

#[test]
fn filters_bind_tighter_than_binary_operators() {
    assert_eq!(ok("{{ 2 * '3'|int }}"), "6");
    assert_eq!(ok("{{ 1 + x is defined }}"), "1");
    assert_eq!(err("{{ -'3'|int }}"), ErrorKind::Type);
}

#[test]
fn printing_values() {
    assert_eq!(ok("{{ [1, 'a', true, none, 1.5, \"it's\", [2.0]] }}"), "[1, 'a', True, None, 1.5, \"it's\", [2.0]]");
}

#[test]
fn context_values() {
    let out = render_with(
        r#"{"user": {"name": "Ada", "tags": ["x", "y"]}, "n": 3, "f": 2.50, "z": null}"#,
        "{{ user.name }} {{ user.tags }} {{ n }} {{ f }} {{ z }} {{ user }}",
        &[],
    )
    .unwrap();
    assert_eq!(out, "Ada ['x', 'y'] 3 2.5 None {'name': 'Ada', 'tags': ['x', 'y']}");
}

#[test]
fn attribute_and_subscript_access() {
    let ctx = r#"{"d": {"a": 1}, "l": [10, 20, 30], "s": "héllo"}"#;
    let r = |t: &str| render_with(ctx, t, &[]);
    assert_eq!(r("{{ d.a }}{{ d['a'] }}{{ l[0] }}{{ l[-1] }}{{ s[1] }}{{ s[-1] }}").unwrap(), "111030éo");
    assert_eq!(r("{{ d.b|default('x') }}{{ l[5]|default('y') }}{{ l.a|default('z') }}").unwrap(), "xyz");
    assert_eq!(r("{{ d.b.c }}"), Err(ErrorKind::Undefined));
    assert_eq!(r("{{ l[1.0]|default('u') }}").unwrap(), "u");
}

#[test]
fn if_for_and_loop() {
    assert_eq!(ok("{% if 0 %}a{% elif '' %}b{% elif 1 %}c{% else %}d{% endif %}"), "c");
    assert_eq!(ok("{% for i in range(3) %}{{ loop.index }}{{ loop.index0 }}{{ loop.first }}{{ loop.last }}{{ loop.length }},{% endfor %}"),
        "10TrueFalse3,21FalseFalse3,32FalseTrue3,");
    assert_eq!(ok("{% for i in [] %}x{% else %}empty{% endfor %}"), "empty");
    assert_eq!(ok("{% for c in 'ab' %}{{ c }}-{% endfor %}"), "a-b-");
    assert_eq!(ok("{% for i in [1,2] %}{% for j in [3] %}{{ loop.length }}{{ i }}{{ j }} {% endfor %}{% endfor %}"), "113 123 ");
    assert_eq!(err("{{ loop }}"), ErrorKind::Undefined);
    assert_eq!(err("{% for i in 5 %}{% endfor %}"), ErrorKind::Type);
}

#[test]
fn for_over_dict_visits_keys_in_order() {
    let out = render_with(r#"{"d": {"z": 1, "a": 2}}"#, "{% for k in d %}{{ k }}{{ d[k] }}{% endfor %}", &[]).unwrap();
    assert_eq!(out, "z1a2");
}

#[test]
fn set_scoping() {
    assert_eq!(ok("{% set a = 1 %}{% for i in [1] %}{% set a = 2 %}{{ a }}{% endfor %}{{ a }}"), "21");
    assert_eq!(ok("{% if true %}{% set a = 5 %}{% endif %}{{ a }}"), "5");
}

#[test]
fn macros() {
    assert_eq!(ok("{% macro f(a, b=a ~ '!') %}{{ a }}{{ b }}{% endmacro %}{{ f('x') }}{{ f('x', b='y') }}"), "xx!xy");
    assert_eq!(
        ok("{% macro fact(n) %}{% if n <= 1 %}1{% else %}{{ n * fact(n - 1)|int }}{% endif %}{% endmacro %}{{ fact(5) }}"),
        "120"
    );
    assert_eq!(err("{% macro f(a) %}{{ a }}{% endmacro %}{{ f() }}"), ErrorKind::Undefined);
    assert_eq!(err("{% macro f(a) %}{% endmacro %}{{ f(1, 2) }}"), ErrorKind::Type);
    assert_eq!(err("{% macro f(a) %}{% endmacro %}{{ f(b=1) }}"), ErrorKind::Type);
    assert_eq!(err("{% macro f(a) %}{% endmacro %}{{ f(1, a=1) }}"), ErrorKind::Type);
    assert_eq!(err("{{ g() }}"), ErrorKind::Undefined);
    assert_eq!(err("{{ 'x'() }}"), ErrorKind::Type);
}

#[test]
fn macro_sees_definition_scope_not_caller() {
    let t = "{% macro f() %}{{ v|default('none') }}{% endmacro %}{% for v in [1] %}{{ f() }}{% endfor %}";
    assert_eq!(ok(t), "none");
}

#[test]
fn range_builtin() {
    assert_eq!(ok("{{ range(3)|join(',') }} {{ range(1, 4)|join(',') }} {{ range(5, 0, -2)|join(',') }}"), "0,1,2 1,2,3 5,3,1");
    assert_eq!(err("{{ range(0, 1, 0) }}"), ErrorKind::Type);
    assert_eq!(err("{{ range('a') }}"), ErrorKind::Type);
    assert_eq!(err("{{ range() }}"), ErrorKind::Type);
    assert_eq!(err("{{ range(1, step=2) }}"), ErrorKind::Type);
}

#[test]
fn filters() {
    assert_eq!(ok("{{ 'aBc'|upper }}{{ 'aBc'|lower }}[{{ ' \t x \n'|trim }}]"), "ABCabc[x]");
    assert_eq!(ok("{{ '<a href=\"x\">&\\'</a>'|escape }}"), "&lt;a href=&#34;x&#34;&gt;&amp;&#39;&lt;/a&gt;");
    assert_eq!(ok("{{ 'aaa'|replace('a', 'ba') }}"), "bababa");
    assert_eq!(ok("{{ 'héllo'|length }}{{ [1,2]|length }}{{ 'ab'|length }}"), "522");
    assert_eq!(ok("{{ ' 12 '|int }}{{ '1.9'|int }}{{ '-1.9'|int }}{{ 'x'|int }}{{ 3.99|int }}{{ true|int }}{{ '1e2'|int }}{{ '.5'|int }}"), "121-10311000");
    assert_eq!(ok("{{ [1, 'a']|join('-') }}{{ 'abc'|join(',') }}{{ [1,2]|join }}"), "1-aa,b,c12");
    assert_eq!(ok("{{ [1,2,3]|first }}{{ [1,2,3]|last }}{{ 'xy'|first }}{{ []|first|default('e') }}"), "13xe");
    assert_eq!(ok("{{ 'abc'|reverse }}{{ [1,2,3]|reverse }}"), "cba[3, 2, 1]");
    assert_eq!(ok("{{ [3, 1.5, 2, true]|sort }}"), "[True, 1.5, 2, 3]");
    assert_eq!(ok("{{ ['b', 'B', 'a', 'A']|sort }}"), "['a', 'A', 'b', 'B']");
    assert_eq!(ok("{{ x|default }}[{{ x|default(1) }}]{{ 5|default(1) }}"), "[1]5");
    assert_eq!(ok("{{ ' a b '|trim|upper }}"), "A B");
}

#[test]
fn filter_errors_and_order() {
    assert_eq!(err("{{ 'a'|nope }}"), ErrorKind::Filter);
    assert_eq!(err("{% if false %}{{ 'a'|nope }}{% endif %}"), ErrorKind::Filter);
    assert_eq!(err("{{ 1 / 0 }}{{ 'a'|nope }}"), ErrorKind::Filter);
    assert_eq!(err("{{ 'a'|nope }}{% if %}"), ErrorKind::Syntax);
    assert_eq!(err("{{ x|upper(1) }}"), ErrorKind::Undefined);
    assert_eq!(err("{{ x|default(1, 2) }}"), ErrorKind::Type);
    assert_eq!(err("{{ 'a'|upper(1) }}"), ErrorKind::Type);
    assert_eq!(err("{{ 'a'|replace('a') }}"), ErrorKind::Type);
    assert_eq!(err("{{ 5|length }}"), ErrorKind::Type);
    assert_eq!(err("{{ [1, 'a']|sort }}"), ErrorKind::Type);
    assert_eq!(err("{{ 5|join }}"), ErrorKind::Type);
}

#[test]
fn undefined_semantics() {
    assert_eq!(ok("{{ x is defined }}{{ x is not defined }}"), "FalseTrue");
    assert_eq!(err("{{ x }}"), ErrorKind::Undefined);
    assert_eq!(err("{% if x %}{% endif %}"), ErrorKind::Undefined);
    assert_eq!(err("{{ x == 1 }}"), ErrorKind::Undefined);
    assert_eq!(err("{{ 1 in x }}"), ErrorKind::Undefined);
    assert_eq!(err("{{ x|upper }}"), ErrorKind::Undefined);
    assert_eq!(ok("{% set y = x %}{{ y is defined }}"), "False");
}

#[test]
fn type_errors() {
    assert_eq!(err("{{ 'a' + 1 }}"), ErrorKind::Type);
    assert_eq!(err("{{ 1 / 0 }}"), ErrorKind::Type);
    assert_eq!(err("{{ 1 % 0 }}"), ErrorKind::Type);
    assert_eq!(err("{{ 1 // 0.0 }}"), ErrorKind::Type);
    assert_eq!(err("{{ 'a' < 1 }}"), ErrorKind::Type);
    assert_eq!(err("{{ 1 in 'abc' }}"), ErrorKind::Type);
    assert_eq!(err("{{ 1 in none }}"), ErrorKind::Type);
    assert_eq!(err("{{ -'a' }}"), ErrorKind::Type);
    assert_eq!(err("{{ 0 ** -1 }}"), ErrorKind::Type);
}

#[test]
fn syntax_errors() {
    for t in [
        "{{ x", "{% if 1 %}", "{# open", "{% endif %}", "{% else %}", "{% foo %}", "{% %}", "{{ }}",
        "{{ 1 + }}", "{{ 'abc }}", "{{ 'a\\q' }}", "{{ 1 @ 2 }}", "{{{ 1 }}}", "{% set x %}",
        "{% for x y %}{% endfor %}", "{% for a, b in x %}{% endfor %}", "{% for x in y if z %}{% endfor %}",
        "{% endfor foo %}", "{{ f(a=1, 2) }}", "{{ f(a=1, a=2) }}", "{{ 1 is none }}", "{{ [1, 2,] }}",
        "{{ 1 if 2 else 3 }}", "{{ {} }}", "{{ x - }}", "{% include 'a' ignore missing %}",
        "{% block a %}{% endblock b %}", "{% block a %}{% endblock %}{% block a %}{% endblock %}",
        "{% macro f(a, a) %}{% endmacro %}", "{% if 1 %}{% extends 'x' %}{% endif %}",
        "{% extends 'a' %}{% extends 'b' %}", "{% raw %}x{% endraw %}", "{% set in = 1 %}",
        "{% if 1 %}{% else %}{% elif 2 %}{% endif %}", "{{ 1.x.5 }}",
    ] {
        assert_eq!(err(t), ErrorKind::Syntax, "{t}");
    }
}

#[test]
fn whitespace_control_and_comments() {
    assert_eq!(ok("a  {{- 'b' -}}  c"), "abc");
    assert_eq!(ok("a \n {%- if true -%} \n b {%- endif %} c"), "ab c");
    assert_eq!(ok("a {#- note -#} b"), "ab");
    assert_eq!(ok("a {# x {{ y }} #} b"), "a  b");
    assert_eq!(ok("{{ 'x' -}}\n\n  y"), "xy");
    assert_eq!(ok("{{ \"%}\" }}"), "%}");
    assert_eq!(ok("x\n{% if true %}\n  y\n{% endif %}\n"), "x\n\n  y\n");
    // Only text is affected, never anything across another tag.
    assert_eq!(ok("{{ 1 }} {{- 2 }}"), "12");
}

#[test]
fn includes_share_scope_one_way() {
    let out = render_with(
        r#"{"v": 1}"#,
        "{% set a = 'A' %}{% include 'inc' %}[{{ b|default('-') }}]",
        &[("inc", "{{ a }}{{ v }}{% set b = 1 %}")],
    )
    .unwrap();
    assert_eq!(out, "A1[-]");
    let out = render_with("{}", "{% for i in [1, 2] %}{% include 'i' %}{% endfor %}", &[("i", "<{{ i }}>")]).unwrap();
    assert_eq!(out, "<1><2>");
    let out = render_with(r#"{"n": "t"}"#, "{% include n ~ '2' %}", &[("t2", "dyn")]).unwrap();
    assert_eq!(out, "dyn");
}

#[test]
fn template_loading_errors() {
    assert_eq!(render_with("{}", "{% include 'nope' %}", &[]), Err(ErrorKind::Template));
    assert_eq!(render_with("{}", "{% extends 'nope' %}", &[]), Err(ErrorKind::Template));
    assert_eq!(render_with("{}", "{% include 3 %}", &[]), Err(ErrorKind::Type));
    assert_eq!(render_with("{}", "{% include x %}", &[]), Err(ErrorKind::Undefined));
    assert_eq!(render_with("{}", "a{% include 'b' %}", &[("b", "{% if %}")]), Err(ErrorKind::Syntax));
    assert_eq!(render_with("{}", "a{% include 'b' %}", &[("b", "{{ 1|zz }}")]), Err(ErrorKind::Filter));
    // Templates that are never loaded are never checked.
    assert_eq!(render_with("{}", "ok", &[("bad", "{% if %}{{ 1|zz }}")]).unwrap(), "ok");
}

#[test]
fn inheritance_basic_and_super() {
    let out = render_with(
        r#"{"title": "T", "items": [3, 1, 2]}"#,
        "{% extends \"base\" %}\n{% set count = items|length %}\n{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}",
        &[
            (
                "base",
                "{% macro item(v) %}#{{ v }}{% endmacro -%}\n<h1>{% block title %}{{ title }}{% endblock %}</h1>\n{% block body %}{{ count }} items{% endblock %}\n{% include \"footer\" %}",
            ),
            ("footer", "-- {{ title|lower }} {{ missing|default(\"end\") }}"),
        ],
    )
    .unwrap();
    assert_eq!(out, "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end");
}

#[test]
fn inheritance_three_levels() {
    let out = render_with(
        "{}",
        "{% extends 'mid' %}{% block a %}[G{{ super() }}]{% endblock %}",
        &[
            ("mid", "{% extends 'base' %}{% block a %}[M{{ super() }}]{% endblock %}{% block b %}mid-b{% endblock %}"),
            ("base", "<{% block a %}base-a{% endblock %}|{% block b %}base-b{% endblock %}>"),
        ],
    )
    .unwrap();
    assert_eq!(out, "<[G[Mbase-a]]|mid-b>");
}

#[test]
fn text_before_extends_is_kept_and_text_after_is_skipped() {
    let out = render_with(
        "{}",
        "head|{% extends 'base' %}skipped{{ nothing_evaluated }}{% block x %}X{% endblock %}tail",
        &[("base", "[{% block x %}b{% endblock %}]")],
    )
    .unwrap();
    assert_eq!(out, "head|[X]");
}

#[test]
fn macro_called_from_set_after_extends_still_returns_text() {
    let out = render_with(
        "{}",
        "{% extends 'base' %}{% macro m() %}M{% endmacro %}{% set v = m() %}",
        &[("base", "{{ v }}")],
    )
    .unwrap();
    assert_eq!(out, "M");
}

#[test]
fn block_scope_is_the_template_scope() {
    let out = render_with(
        "{}",
        "{% set top = 'T' %}{% for i in [1] %}{% block b %}{{ i|default('noloop') }}{{ top }}{% endblock %}{% endfor %}",
        &[],
    )
    .unwrap();
    assert_eq!(out, "noloopT");
}

#[test]
fn super_errors() {
    assert_eq!(err("{% block a %}{{ super() }}{% endblock %}"), ErrorKind::Undefined);
    assert_eq!(
        render_with("{}", "{% extends 'b' %}{% block a %}{{ super(1) }}{% endblock %}", &[("b", "{% block a %}{% endblock %}")]),
        Err(ErrorKind::Type)
    );
    assert_eq!(err("{{ super() }}"), ErrorKind::Undefined);
}

#[test]
fn rendering_is_all_or_nothing() {
    assert_eq!(err("lots of output {{ 1 }} {{ missing }}"), ErrorKind::Undefined);
}

#[test]
fn large_loops_are_fast_enough() {
    let out = render("{% for i in range(100000) %}{{ i }}{% endfor %}").unwrap();
    assert_eq!(out.len(), 488_890);
}
