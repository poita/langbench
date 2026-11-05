module tests.parser_test;

import jtemplate;

private ErrorKind kindOf(string src)
{
    try
        parseTemplate("t", src);
    catch (TemplateError e)
        return e.kind;
    assert(0, "no error for: " ~ src);
}

unittest // a well-formed template parses and records its blocks
{
    auto t = parseTemplate("t",
        "{% extends 'base' %}{% block a %}x{% block b %}y{% endblock %}{% endblock a %}");
    assert(t.name == "t");
    assert(t.body.length == 2);
    assert(("a" in t.blocks) !is null && ("b" in t.blocks) !is null);
}

unittest // statements
{
    auto t = parseTemplate("t",
        "{% set x = 1 %}{% macro m(a, b=2) %}{% endmacro %}"
        ~ "{% if x %}{% elif y %}{% else %}{% endif %}"
        ~ "{% for i in x %}{% else %}{% endfor %}{% include 'z' %}");
    assert(t.body.length == 5);
    assert(t.body[0].kind == NodeKind.set);
    assert(t.body[1].kind == NodeKind.macro_);
    assert(t.body[2].kind == NodeKind.if_);
    assert(t.body[3].kind == NodeKind.for_);
    assert(t.body[4].kind == NodeKind.include);
}

unittest // precedence: not binds looser than ==, filters bind tighter than *
{
    auto t = parseTemplate("t", "{{ not a == b }}{{ a * b|int }}");
    auto p0 = cast(PrintNode) t.body[0];
    assert(p0.expr.kind == ExprKind.not);
    auto p1 = cast(PrintNode) t.body[1];
    assert(p1.expr.kind == ExprKind.binary);
    assert((cast(BinaryExpr) p1.expr).rhs.kind == ExprKind.filter);
}

unittest // unary minus is folded into number literals
{
    auto t = parseTemplate("t", "{{ -3 }}");
    auto lit = cast(LiteralExpr) (cast(PrintNode) t.body[0]).expr;
    assert(lit !is null && lit.value.i == -3);
}

unittest // syntax errors
{
    foreach (bad; [
        "{% if x %}", "{% for x in y %}", "{% endif %}", "{% else %}",
        "{% frobnicate %}", "{% %}", "{{ }}", "{{ 1 + }}", "{{ a b }}",
        "{% set x %}", "{% for x y %}{% endfor %}", "{% for a, b in c %}{% endfor %}",
        "{% block a %}{% endblock b %}", "{% block a %}{% endblock %}{% block a %}{% endblock %}",
        "{{ f(a=1, 2) }}", "{{ f(a=1, a=2) }}", "{{ x is foo }}",
        "{% macro m(a, a) %}{% endmacro %}", "{% endfor extra %}{% for x in y %}",
        "{% extends 'a' %}{% extends 'b' %}", "{% if x %}{% extends 'a' %}{% endif %}",
        "{% macro m() %}{% extends 'a' %}{% endmacro %}", "{% raw %}", "{{ [1, 2 }}",
        "{% if a %}{% else %}{% elif b %}{% endif %}", "{% include 'x' ignore missing %}",
        "{{ a if b else c }}", "{{ x[1:2] }}", "{% set a, b = 1 %}",
    ])
        assert(kindOf(bad) == ErrorKind.syntax, bad);
}

unittest // unknown filters are reported only after the whole template parsed
{
    assert(kindOf("{{ x|nosuch }}") == ErrorKind.filter);
    assert(kindOf("{% macro m() %}{{ x|nosuch }}{% endmacro %}") == ErrorKind.filter);
    assert(kindOf("{{ x|nosuch }}{% if %}") == ErrorKind.syntax);
}

unittest // filter names resolve to ids
{
    assert(filterId("upper") == FilterId.upper);
    assert(filterId("default") == FilterId.default_);
    assert(filterId("nope") == FilterId.unknown);
}
