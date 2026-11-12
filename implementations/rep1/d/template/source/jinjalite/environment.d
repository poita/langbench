/// The public entry point: a registry of named templates and `render`.
module jinjalite.environment;

import jinjalite.ast : Template;
import jinjalite.errors;
import jinjalite.interpreter;
import jinjalite.parser : parseTemplate;
import jinjalite.value;

/++
    A set of named templates that can render, include and extend one another.

    Templates are parsed and checked lazily, at most once each, the first time a
    rendering needs them.
+/
final class Environment : TemplateSource
{
    private string[string] sources_;
    private Template[string] loaded_;

    /// Register (or replace) the template called `name`.
    void addTemplate(string name, string source)
    {
        sources_[name] = source;
        loaded_.remove(name);
    }

    /// True when a template called `name` is registered.
    bool hasTemplate(string name) const
    {
        return (name in sources_) !is null;
    }

    /// Parse and check the template called `name` (cached); see `TemplateSource.load`.
    Template load(string name)
    {
        if (auto t = name in loaded_)
            return *t;
        auto src = name in sources_;
        if (src is null)
            throw new TemplateError(ErrorKind.missingTemplate, "no template named '" ~ name ~ "'");
        auto tpl = parseTemplate(name, *src);
        loaded_[name] = tpl;
        return tpl;
    }

    /++
        Render the template `name` with the members of the dict `context` as its
        variables. All-or-nothing: any language error is thrown as a `TemplateError`
        and no partial output is returned.
    +/
    string render(string name, Value context)
    {
        if (context.kind != Kind.dict)
            throw new TemplateError(ErrorKind.type, "the render context must be a dict");
        auto main = load(name);
        return new Interpreter(this).render(main, context.asDict);
    }

    /// Convenience: render `source` as an anonymous template that can still use the registered ones.
    string renderString(string source, Value context)
    {
        enum anonymous = "<string>";
        addTemplate(anonymous, source);
        scope (exit)
            sources_.remove(anonymous), loaded_.remove(anonymous);
        return render(anonymous, context);
    }
}

version (unittest)
{
    import jinjalite.json : parseJson;

    private string renderOne(string src, string json = "{}")
    {
        return new Environment().renderString(src, parseJson(json));
    }

    private ErrorKind errorOf(string src, string json = "{}")
    {
        import std.exception : collectException;
        auto e = cast(TemplateError) collectException(renderOne(src, json));
        assert(e !is null, "expected an error for: " ~ src);
        return e.kind;
    }
}

unittest
{
    assert(renderOne("") == "");
    assert(renderOne("plain {text}") == "plain {text}");
    assert(renderOne("Hello {{ name }}!", `{"name": "Ada"}`) == "Hello Ada!");
    assert(renderOne("{{ 1 + 2 * 3 }} {{ 7 / 2 }} {{ 7 // 2 }} {{ -7 % 3 }} {{ 2 ** 10 }}") == "7 3.5 3 2 1024");
    assert(renderOne(`{{ "a" ~ 1 ~ none ~ true }}`) == "a1NoneTrue");
    assert(renderOne("{{ 0 or 'x' }}{{ '' and 1 }}|{{ 1 and 2 }}{{ not 0 }}") == "x|2True");
    assert(renderOne("{{ 1 < 2 < 3 }}{{ 1 < 3 < 2 }}{{ 1 == 1.0 }}") == "TrueFalseTrue");
    assert(renderOne("{{ [1, 'a', none] }}") == "[1, 'a', None]");
    assert(renderOne(`{{ u.name }}`, `{"u": {"name": "x"}}`) == "x");
    assert(renderOne(`{{ l[-1] }}{{ s[1] }}`, `{"l": [1,2,3], "s": "héy"}`) == "3é");
}

unittest
{
    assert(renderOne("{% if a %}A{% elif b %}B{% else %}C{% endif %}", `{"a": 0, "b": 1}`) == "B");
    assert(renderOne("{% for x in xs %}{{ loop.index }}/{{ loop.length }}{{ x }}{% if not loop.last %},{% endif %}{% endfor %}",
        `{"xs": ["a", "b"]}`) == "1/2a,2/2b");
    assert(renderOne("{% for x in xs %}{{ x }}{% else %}empty{% endfor %}", `{"xs": []}`) == "empty");
    assert(renderOne("{% for k in d %}{{ k }}{% endfor %}", `{"d": {"z": 1, "a": 2}}`) == "za");
    assert(renderOne("{% for c in 'hé' %}[{{ c }}]{% endfor %}") == "[h][é]");
    assert(renderOne("{% for i in range(3, 0, -1) %}{{ i }}{% endfor %}{{ range(4)|join(',') }}") == "3210,1,2,3");
    // set inside a loop body is local to the iteration.
    assert(renderOne("{% set n = 1 %}{% for i in range(2) %}{% set m = i %}{{ m }}{% endfor %}{{ m is defined }}") == "01False");
}

unittest
{
    assert(renderOne("{% macro f(a, b=2) %}{{ a }}-{{ b }}{% endmacro %}{{ f(1) }} {{ f(1, 3) }} {{ f(b=5, a=0) }}") == "1-2 1-3 0-5");
    assert(renderOne("{% macro fact(n) %}{% if n <= 1 %}1{% else %}{{ n * fact(n - 1)|int }}{% endif %}{% endmacro %}{{ fact(10) }}")
        == "3628800");
    // Macros see later sets of their defining scope but not the caller's locals.
    assert(renderOne("{% macro show() %}{{ w }}{{ i is defined }}{% endmacro %}{% set w = 'W' %}{% for i in [1] %}{{ show() }}{% endfor %}")
        == "WFalse");
}

unittest
{
    auto env = new Environment;
    env.addTemplate("page", `{% extends "base" %}{% set count = items|length %}` ~
        `{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}`);
    env.addTemplate("base", "{% macro item(v) %}#{{ v }}{% endmacro -%}\n" ~
        "<h1>{% block title %}{{ title }}{% endblock %}</h1>\n{% block body %}{{ count }} items{% endblock %}\n" ~
        `{% include "footer" %}`);
    env.addTemplate("footer", `-- {{ title|lower }} {{ missing|default("end") }}`);
    auto ctx = parseJson(`{"title": "T", "items": [3, 1, 2]}`);
    assert(env.render("page", ctx) == "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end");
}

unittest
{
    auto env = new Environment;
    env.addTemplate("a", `{% extends "b" %}{% block x %}A[{{ super() }}]{% endblock %}`);
    env.addTemplate("b", `{% extends "c" %}{% block x %}B[{{ super() }}]{% endblock %}`);
    env.addTemplate("c", `<{% block x %}C{% endblock %}>`);
    assert(env.render("a", parseJson("{}")) == "<A[B[C]]>");
    // Text before `extends` is rendered; text after it is not.
    env.addTemplate("d", `before {% extends "c" %} skipped {% block x %}D{% endblock %}`);
    assert(env.render("d", parseJson("{}")) == "before <D>");
}

unittest
{
    assert(errorOf("{{ nope }}") == ErrorKind.undefined);
    assert(errorOf("{{ a.b.c }}", `{"a": {}}`) == ErrorKind.undefined);
    assert(errorOf("{% if nope %}{% endif %}") == ErrorKind.undefined);
    assert(errorOf("{{ super() }}") == ErrorKind.undefined);
    assert(errorOf("{{ 'a' + 1 }}") == ErrorKind.type);
    assert(errorOf("{{ 1 / 0 }}") == ErrorKind.type);
    assert(errorOf("{% for x in 3 %}{% endfor %}") == ErrorKind.type);
    assert(errorOf("{{ 3() }}") == ErrorKind.type);
    assert(errorOf("{{ nope() }}") == ErrorKind.undefined);
    assert(errorOf(`{% include "missing" %}`) == ErrorKind.missingTemplate);
    assert(errorOf(`{% include 3 %}`) == ErrorKind.type);
    assert(errorOf("{{ x|bogus }}") == ErrorKind.filter);
    assert(errorOf("{{ x") == ErrorKind.syntax);
    // Output produced before an error is not returned: rendering is all-or-nothing.
    assert(errorOf("text {{ nope }}") == ErrorKind.undefined);
}

unittest
{
    // Unused templates are never checked.
    auto env = new Environment;
    env.addTemplate("main", "ok");
    env.addTemplate("broken", "{% if %}");
    assert(env.render("main", parseJson("{}")) == "ok");
    assert(env.hasTemplate("broken") && !env.hasTemplate("nope"));
}
