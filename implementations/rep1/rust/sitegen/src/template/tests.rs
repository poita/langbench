use super::*;

fn render(templates: &[(&str, &str)], ctx: Dict) -> Result<String, Error> {
    let mut env = Environment::new();
    for (n, s) in templates {
        env.add_template(*n, *s);
    }
    env.render(templates[0].0, &ctx)
}

fn r(src: &str) -> String {
    render(&[("main", src)], Dict::new()).unwrap()
}

fn kind(src: &str) -> ErrorKind {
    render(&[("main", src)], Dict::new()).unwrap_err().kind()
}

fn strs(items: &[&str]) -> Value {
    Value::list(items.iter().map(Value::str).collect())
}

fn ada() -> Dict {
    let mut user = Dict::new();
    user.insert("name", Value::str("Ada"));
    user.insert("tags", strs(&["x", "y"]));
    let mut ctx = Dict::new();
    ctx.insert("user", Value::dict(user));
    ctx.insert("n", Value::Int(3));
    ctx
}

#[test]
fn spec_example_loops_and_whitespace_control() {
    let src = "Hi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n{% endfor -%}\n{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %} {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, \"s\"] }}";
    assert_eq!(
        render(&[("main", src)], ada()).unwrap(),
        "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']"
    );
}

#[test]
fn spec_example_unclosed_for_is_syntax_error() {
    let src = "Hi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n{% if n > 2 %}big{% endif %}";
    assert_eq!(
        render(&[("main", src)], ada()).unwrap_err().kind(),
        ErrorKind::Syntax
    );
}

#[test]
fn spec_example_inheritance_macros_include() {
    let mut ctx = Dict::new();
    ctx.insert("title", Value::str("T"));
    ctx.insert(
        "items",
        Value::list(vec![Value::Int(3), Value::Int(1), Value::Int(2)]),
    );
    let out = render(
        &[
            (
                "page",
                "{% extends \"base\" %}\n{% set count = items|length %}\n{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}",
            ),
            (
                "base",
                "{% macro item(v) %}#{{ v }}{% endmacro -%}\n<h1>{% block title %}{{ title }}{% endblock %}</h1>\n{% block body %}{{ count }} items{% endblock %}\n{% include \"footer\" %}",
            ),
            ("footer", "-- {{ title|lower }} {{ missing|default(\"end\") }}"),
        ],
        ctx,
    )
    .unwrap();
    assert_eq!(
        out,
        "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end"
    );
}

#[test]
fn spec_example_undefined_attribute() {
    let mut a = Dict::new();
    a.insert("b", Value::Int(1));
    let mut ctx = Dict::new();
    ctx.insert("a", Value::dict(a));
    let e = render(&[("main", "{{ a.b }}{{ a.c.d }}")], ctx).unwrap_err();
    assert_eq!(e.kind(), ErrorKind::Undefined);
}

#[test]
fn text_and_comments() {
    assert_eq!(r("a{# comment #}b"), "ab");
    assert_eq!(r("a  {#- c -#}  b"), "ab");
    assert_eq!(r("{ } {x} }}"), "{ } {x} }}");
    assert_eq!(kind("{# open"), ErrorKind::Syntax);
    assert_eq!(kind("{{ 1"), ErrorKind::Syntax);
    assert_eq!(kind("{{{ 1 }}}"), ErrorKind::Syntax);
}

#[test]
fn whitespace_control() {
    assert_eq!(r("a \n {{- 1 -}} \n b"), "a1b");
    assert_eq!(r("a {%- if true -%} b {%- endif %} c"), "ab c");
    assert_eq!(r("{{ 5 -}}  x"), "5x");
    assert_eq!(kind("{{ 5 - }}"), ErrorKind::Syntax);
    assert_eq!(r("{{ \"%}\" }}"), "%}");
}

#[test]
fn literals_and_printing() {
    assert_eq!(
        r("{{ 1 }} {{ 1.5 }} {{ true }} {{ false }} {{ none }} {{ 'a\\n\\t\\\\' }}"),
        "1 1.5 True False None a\n\t\\"
    );
    assert_eq!(
        r("{{ [1, 'a', none, true, 1.0] }}"),
        "[1, 'a', None, True, 1.0]"
    );
    assert_eq!(
        r("{{ 'it\\'s' }} {{ [\"it's\", 'say \"hi\"'] }}"),
        "it's [\"it's\", 'say \"hi\"']"
    );
    assert_eq!(kind("{{ 'a\\q' }}"), ErrorKind::Syntax);
    assert_eq!(kind("{{ 'abc }}"), ErrorKind::Syntax);
}

#[test]
fn arithmetic() {
    assert_eq!(r("{{ 1 + 2 * 3 }} {{ (1 + 2) * 3 }} {{ 7 // 2 }} {{ -7 // 2 }} {{ -7 % 3 }} {{ 7 % -3 }}"), "7 9 3 -4 2 -2");
    assert_eq!(
        r("{{ 6 / 3 }} {{ 7.0 // 2 }} {{ 2 ** 10 }} {{ 2 ** -1 }} {{ -2 ** 2 }}"),
        "2.0 3.0 1024 0.5 4"
    );
    assert_eq!(
        r("{{ 1 + 1.5 }} {{ true + true }} {{ 'ab' * 3 }} {{ 3 * 'ab' }} {{ 'a' * -1 }}|"),
        "2.5 2 ababab ababab |"
    );
    assert_eq!(
        r("{{ [1] + [2, 3] }} {{ 'a' + 'b' }} {{ 1 ~ 'x' ~ 2.0 }}"),
        "[1, 2, 3] ab 1x2.0"
    );
    assert_eq!(r("{{ 0.1 + 0.2 }}"), "0.30000000000000004");
    assert_eq!(kind("{{ 1 / 0 }}"), ErrorKind::Type);
    assert_eq!(kind("{{ 1 // 0 }}"), ErrorKind::Type);
    assert_eq!(kind("{{ 1 % 0 }}"), ErrorKind::Type);
    assert_eq!(kind("{{ 'a' - 1 }}"), ErrorKind::Type);
    assert_eq!(kind("{{ 1 + 'a' }}"), ErrorKind::Type);
    assert_eq!(kind("{{ 0 ** -1 }}"), ErrorKind::Type);
}

#[test]
fn precedence() {
    // Filters bind tighter than `*`: `'5' * (2|int)`.
    assert_eq!(r("{{ '5' * 2|int }}"), "55");
    // `~` binds tighter than `+`.
    assert_eq!(r("{{ '1' + 2 ~ 3 }}"), "123");
    assert_eq!(kind("{{ 1 + 2 ~ 3 }}"), ErrorKind::Type);
    assert_eq!(r("{{ 'a' ~ 'b' + 'c' }}"), "abc");
    assert_eq!(r("{{ not 1 == 2 }} {{ not true or true }}"), "True True");
    assert_eq!(
        r("{{ 1 < 2 < 3 }} {{ 3 > 2 > 2 }} {{ 1 == 1.0 }} {{ true == 1 }}"),
        "True False True True"
    );
    assert_eq!(r("{{ 0 or 'x' }} {{ '' and 1 }}| {{ 1 and 2 }}"), "x | 2");
    assert_eq!(r("{{ 1 + x is defined }}"), "1");
}

#[test]
fn comparisons_and_membership() {
    assert_eq!(
        r("{{ 'a' < 'b' }} {{ 'ab' < 'a' }} {{ 'a' <= 'a' }}"),
        "True False True"
    );
    assert_eq!(
        r("{{ 'b' in 'abc' }} {{ 'z' not in 'abc' }} {{ '' in 'abc' }}"),
        "True True True"
    );
    assert_eq!(r("{{ 2 in [1, 2] }} {{ 3 in [1, 2] }}"), "True False");
    assert_eq!(
        r("{{ [1, [2]] == [1, [2]] }} {{ 1 == '1' }} {{ none == none }} {{ none == 0 }}"),
        "True False True False"
    );
    assert_eq!(kind("{{ [1] < [2] }}"), ErrorKind::Type);
    assert_eq!(kind("{{ 1 in 5 }}"), ErrorKind::Type);
    assert_eq!(kind("{{ 1 in 'abc' }}"), ErrorKind::Type);
}

#[test]
fn if_for_else() {
    assert_eq!(
        r("{% if 0 %}a{% elif '' %}b{% elif [1] %}c{% else %}d{% endif %}"),
        "c"
    );
    assert_eq!(r("{% for x in [] %}a{% else %}empty{% endfor %}"), "empty");
    assert_eq!(
        r("{% for x in 'ab' %}{{ loop.index }}{{ loop.index0 }}{{ loop.first }}{{ loop.last }}{{ loop.length }}{{ x }},{% endfor %}"),
        "10TrueFalse2a,21FalseTrue2b,"
    );
    assert_eq!(r("{% for i in range(3) %}{% for j in range(i) %}{{ loop.index }}{% endfor %}|{% endfor %}"), "|1|12|");
    assert_eq!(r("{% for k in [3, 4] %}{{ k }}{% endfor %}"), "34");
    assert_eq!(
        r("{{ range(2, 10, 3)|join(',') }} {{ range(3, 0, -1)|join(',') }}"),
        "2,5,8 3,2,1"
    );
    assert_eq!(kind("{% for x in 5 %}{% endfor %}"), ErrorKind::Type);
    assert_eq!(kind("{{ loop }}"), ErrorKind::Undefined);
}

#[test]
fn scoping_rules() {
    assert_eq!(
        r("{% set a = 1 %}{% for i in [1] %}{% set a = 2 %}{{ a }}{% endfor %}{{ a }}"),
        "21"
    );
    assert_eq!(
        r("{% macro m() %}{{ x }}{% endmacro %}{% set x = 5 %}{{ m() }}"),
        "5"
    );
    // A macro does not see the caller's local variables.
    assert_eq!(
        kind("{% macro m() %}{{ i }}{% endmacro %}{% for i in [1] %}{{ m() }}{% endfor %}"),
        ErrorKind::Undefined
    );
}

#[test]
fn for_else_body_has_its_own_scope() {
    // Matches Jinja2: bindings made in the `else` body do not leak out of it,
    // but the body still sees the enclosing scope.
    assert_eq!(r("{% set a = 1 %}{% for v in [] %}{% else %}{{ a }}{% set b = 2 %}{{ b }}{% endfor %}{{ b|default('unset') }}"), "12unset");
}

#[test]
fn macros() {
    assert_eq!(r("{% macro f(a, b=2) %}{{ a }}-{{ b }}{% endmacro %}{{ f(1) }} {{ f(1, 3) }} {{ f(1, b=4) }} {{ f(b=5, a=6) }}"), "1-2 1-3 1-4 6-5");
    assert_eq!(r("{% macro f(n) %}{% if n <= 1 %}1{% else %}{{ n * f(n - 1)|int }}{% endif %}{% endmacro %}{{ f(5) }}"), "120");
    assert_eq!(
        r("{% macro f(a, b=a) %}{{ b }}{% endmacro %}{{ f(7) }}"),
        "7"
    );
    assert_eq!(
        r("{% macro f(a) %}{{ a is defined }}{% endmacro %}{{ f() }}"),
        "False"
    );
    assert_eq!(
        kind("{% macro f(a) %}{% endmacro %}{{ f(1, 2) }}"),
        ErrorKind::Type
    );
    assert_eq!(
        kind("{% macro f(a) %}{% endmacro %}{{ f(c=2) }}"),
        ErrorKind::Type
    );
    assert_eq!(
        kind("{% macro f(a) %}{% endmacro %}{{ f(1, a=2) }}"),
        ErrorKind::Type
    );
    assert_eq!(
        kind("{% macro f(a) %}{{ a }}{% endmacro %}{{ f() }}"),
        ErrorKind::Undefined
    );
    assert_eq!(kind("{{ nope() }}"), ErrorKind::Undefined);
    assert_eq!(kind("{{ 'a'() }}"), ErrorKind::Type);
    assert_eq!(kind("{% macro f(a, a) %}{% endmacro %}"), ErrorKind::Syntax);
}

#[test]
fn filters() {
    assert_eq!(
        r("{{ 'aBc'|upper }}{{ 'aBc'|lower }}[{{ '  x \\n'|trim }}]"),
        "ABCabc[x]"
    );
    assert_eq!(
        r("{{ '<a href=\"x\">&\\'</a>'|escape }}"),
        "&lt;a href=&#34;x&#34;&gt;&amp;&#39;&lt;/a&gt;"
    );
    assert_eq!(
        r("{{ 'a-b-c'|replace('-', '+') }} {{ 'aaa'|replace('aa', 'b') }}"),
        "a+b+c ba"
    );
    assert_eq!(
        r("{{ 'héllo'|length }} {{ [1,2]|length }} {{ 'x'|length }}"),
        "5 2 1"
    );
    assert_eq!(r("{{ '12'|int }} {{ ' -3.9 '|int }} {{ 'x'|int }} {{ 2.7|int }} {{ true|int }} {{ none|int }}"), "12 -3 0 2 1 0");
    assert_eq!(
        r("{{ [1, 'a', 2.5]|join(', ') }} {{ 'abc'|join('-') }} {{ [1,2]|join }}"),
        "1, a, 2.5 a-b-c 12"
    );
    assert_eq!(
        r("{{ [1,2,3]|first }} {{ [1,2,3]|last }} {{ 'abc'|first }}"),
        "1 3 a"
    );
    assert_eq!(r("{{ [] |first|default('none!') }}"), "none!");
    assert_eq!(
        r("{{ [3,1,2]|reverse|join }} {{ 'abc'|reverse }}"),
        "213 cba"
    );
    assert_eq!(
        r("{{ [3, 1.5, 2, 1]|sort|join(',') }} {{ ['b', 'A', 'a', 'B']|sort|join(',') }}"),
        "1,1.5,2,3 A,a,b,B"
    );
    assert_eq!(
        r("{{ x|default }}|{{ x|default('d') }}|{{ 0|default('d') }}"),
        "|d|0"
    );
    assert_eq!(kind("{{ 1|nope }}"), ErrorKind::Filter);
    assert_eq!(
        kind("{% if false %}{{ 1|nope }}{% endif %}"),
        ErrorKind::Filter
    );
    assert_eq!(kind("{{ x|upper(1) }}"), ErrorKind::Undefined);
    assert_eq!(kind("{{ x|default(1, 2) }}"), ErrorKind::Type);
    assert_eq!(kind("{{ 'a'|upper(1) }}"), ErrorKind::Type);
    assert_eq!(kind("{{ 5|length }}"), ErrorKind::Type);
    assert_eq!(kind("{{ [1, 'a']|sort }}"), ErrorKind::Type);
}

#[test]
fn undefined_value() {
    assert_eq!(
        r("{{ x is defined }}{{ x is not defined }}{{ y|default(1) }}"),
        "FalseTrue1"
    );
    assert_eq!(r("{% set z = x %}{{ z is defined }}"), "False");
    assert_eq!(
        r("{{ [1][5] is defined }} {{ 'a'.b is defined }}"),
        "False False"
    );
    assert_eq!(kind("{{ x }}"), ErrorKind::Undefined);
    assert_eq!(kind("{% if x %}{% endif %}"), ErrorKind::Undefined);
    assert_eq!(kind("{{ x == 1 }}"), ErrorKind::Undefined);
    assert_eq!(kind("{{ x + 1 }}"), ErrorKind::Undefined);
    assert_eq!(kind("{% for i in x %}{% endfor %}"), ErrorKind::Undefined);
    assert_eq!(kind("{{ x.y }}"), ErrorKind::Undefined);
    assert_eq!(kind("{{ x|upper }}"), ErrorKind::Undefined);
}

#[test]
fn subscripts() {
    assert_eq!(
        r("{{ [1, 2, 3][-1] }} {{ 'abc'[1] }} {{ 'abc'[-3] }}"),
        "3 b a"
    );
    let mut d = Dict::new();
    d.insert("k", Value::Int(1));
    let mut ctx = Dict::new();
    ctx.insert("d", Value::dict(d));
    assert_eq!(
        render(
            &[(
                "m",
                "{{ d['k'] }} {{ d.k }} {{ d.z is defined }} {{ d[0] is defined }} {{ 'k' in d }}"
            )],
            ctx
        )
        .unwrap(),
        "1 1 False False True"
    );
}

#[test]
fn inheritance_chains() {
    let out = render(
        &[
            (
                "c",
                "{% extends 'b' %}{% block x %}C[{{ super() }}]{% endblock %}",
            ),
            (
                "b",
                "{% extends 'a' %}{% block x %}B[{{ super() }}]{% endblock %}",
            ),
            (
                "a",
                "<{% block x %}A{% endblock %}>{% block y %}y{% endblock %}",
            ),
        ],
        Dict::new(),
    )
    .unwrap();
    assert_eq!(out, "<C[B[A]]>y");
}

#[test]
fn child_output_outside_blocks_is_skipped() {
    let out = render(
        &[
            ("c", "before {% extends 'p' %} skipped {{ 1 }}{% set v = 'V' %}{% block b %}[{{ v }}]{% endblock %}"),
            ("p", "P{% block b %}default{% endblock %}Q"),
        ],
        Dict::new(),
    )
    .unwrap();
    assert_eq!(out, "before P[V]Q");
}

#[test]
fn block_scope_does_not_see_loop_variables() {
    assert_eq!(
        kind("{% for i in [1] %}{% block b %}{{ i }}{% endblock %}{% endfor %}"),
        ErrorKind::Undefined
    );
    assert_eq!(r("{% set t = 1 %}{% block b %}{{ t }}{% endblock %}"), "1");
}

#[test]
fn include_scoping() {
    let out = render(
        &[
            ("m", "{% set a = 1 %}{% for i in [5] %}{% include 'inc' %}{% endfor %}{{ b is defined }}"),
            ("inc", "{{ a }}{{ i }}{% set b = 2 %}"),
        ],
        Dict::new(),
    )
    .unwrap();
    assert_eq!(out, "15False");
    assert_eq!(kind("{% include 'nope' %}"), ErrorKind::Template);
    assert_eq!(kind("{% include 5 %}"), ErrorKind::Type);
    assert_eq!(kind("{% include x %}"), ErrorKind::Undefined);
}

#[test]
fn syntax_errors() {
    for src in [
        "{% if x %}",
        "{% endif %}",
        "{% for a, b in x %}{% endfor %}",
        "{% for x in y if z %}{% endfor %}",
        "{% set a, b = 1 %}",
        "{% include 'x' ignore missing %}",
        "{% block x scoped %}{% endblock %}",
        "{% raw %}",
        "{% %}",
        "{% block a %}{% endblock b %}",
        "{% block a %}{% endblock %}{% block a %}{% endblock %}",
        "{% if true %}{% extends 'x' %}{% endif %}",
        "{% extends 'x' %}{% extends 'y' %}",
        "{{ 1 is odd }}",
        "{{ a if b else c }}",
        "{{ [1, 2,] }}",
        "{{ f(a=1, 2) }}",
        "{{ f(a=1, a=2) }}",
        "{{ 1 +  }}",
        "{{ x.0 }}",
        "{% else %}",
        "{% if x %}{% else %}{% else %}{% endif %}",
        "{% if x %}{% else %}{% elif y %}{% endif %}",
    ] {
        assert_eq!(kind(src), ErrorKind::Syntax, "{}", src);
    }
}

#[test]
fn unloaded_templates_are_never_checked() {
    let out = render(&[("a", "ok"), ("broken", "{% if %}")], Dict::new()).unwrap();
    assert_eq!(out, "ok");
}

#[test]
fn keyword_arguments_to_range_are_type_errors() {
    assert_eq!(kind("{{ range(1, step=2) }}"), ErrorKind::Type);
    assert_eq!(kind("{{ range() }}"), ErrorKind::Type);
    assert_eq!(kind("{{ range(1, 2, 0) }}"), ErrorKind::Type);
    assert_eq!(kind("{{ range('a') }}"), ErrorKind::Type);
}

#[test]
fn context_values_are_shared_and_ordered() {
    let mut inner = Dict::new();
    inner.insert("z", Value::Int(1));
    inner.insert("a", Value::Int(2));
    let mut ctx = Dict::new();
    ctx.insert("d", Value::dict(inner));
    assert_eq!(
        render(
            &[("m", "{% for k in d %}{{ k }}{{ d[k] }}{% endfor %}")],
            ctx
        )
        .unwrap(),
        "z1a2"
    );
}
