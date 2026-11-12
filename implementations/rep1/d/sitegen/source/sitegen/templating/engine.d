/**
 * The public face of the template engine.
 */
module sitegen.templating.engine;

import sitegen.templating.ast : Template;
import sitegen.templating.errors;
import sitegen.templating.interp;
import sitegen.templating.parser;
import sitegen.templating.value;

/**
 * A set of named templates that can be rendered.
 *
 * Templates are loaded lazily: the first time one is needed it is lexed,
 * parsed and checked, and the result is cached.  A template that is never
 * needed is never checked.
 */
final class TemplateEngine : TemplateLoader
{
    private string[string] sources;
    private Template[string] loaded;
    private Interpreter interp;

    ///
    this()
    {
        interp = new Interpreter(this);
    }

    /// Registers a template under `name`; `source` is its text.
    void addTemplate(string name, string source)
    {
        sources[name] = source;
        loaded.remove(name);
    }

    /// Whether a template named `name` is registered.
    override bool hasTemplate(string name)
    {
        return (name in sources) !is null;
    }

    /// Loads the named template, parsing it on first use.
    override Template load(string name)
    {
        if (auto t = name in loaded) return *t;
        auto src = name in sources;
        if (src is null) templateError("no template named " ~ name);
        auto t = parseTemplate(name, *src);
        loaded[name] = t;
        return t;
    }

    /**
     * Renders the template `name`, with `context` as the variables of its
     * root scope.
     *
     * Throws: `TemplateException` on any template error.
     */
    string render(string name, Value[string] context)
    {
        return interp.render(name, context);
    }
}

unittest
{
    auto e = new TemplateEngine;
    e.addTemplate("main", "Hi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n{% endfor -%}\n"
            ~ "{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %} {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, \"s\"] }}");
    auto user = new Dict;
    user.set("name", Value.str("Ada"));
    user.set("tags", Value.list(["x", "y"]));
    Value[string] ctx;
    ctx["user"] = Value.dict(user);
    ctx["n"] = Value.integer(3);
    assert(e.render("main", ctx) == "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']");
}

unittest
{
    auto e = new TemplateEngine;
    e.addTemplate("page", "{% extends \"base\" %}\n{% set count = items|length %}\n"
            ~ "{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}");
    e.addTemplate("base", "{% macro item(v) %}#{{ v }}{% endmacro -%}\n<h1>{% block title %}{{ title }}{% endblock %}</h1>\n"
            ~ "{% block body %}{{ count }} items{% endblock %}\n{% include \"footer\" %}");
    e.addTemplate("footer", "-- {{ title|lower }} {{ missing|default(\"end\") }}");
    Value[string] ctx;
    ctx["title"] = Value.str("T");
    ctx["items"] = Value.list([Value.integer(3), Value.integer(1), Value.integer(2)]);
    assert(e.render("page", ctx) == "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end");
}

unittest
{
    import std.exception : collectException;

    auto e = new TemplateEngine;
    e.addTemplate("a", "{{ a.b }}{{ a.c.d }}");
    e.addTemplate("b", "{% for x in y %}");
    e.addTemplate("c", "{% include \"nope\" %}");
    e.addTemplate("d", "{{ 1 / 0 }}");
    e.addTemplate("e", "{{ x|bogus }}");
    auto inner = new Dict;
    inner.set("b", Value.integer(1));
    Value[string] ctx;
    ctx["a"] = Value.dict(inner);
    assert(collectException!TemplateException(e.render("a", ctx)).kind == ErrorKind.undefined);
    assert(collectException!TemplateException(e.render("b", ctx)).kind == ErrorKind.syntax);
    assert(collectException!TemplateException(e.render("c", ctx)).kind == ErrorKind.template_);
    assert(collectException!TemplateException(e.render("d", ctx)).kind == ErrorKind.type);
    assert(collectException!TemplateException(e.render("e", ctx)).kind == ErrorKind.filter);
}

unittest
{
    auto e = new TemplateEngine;
    e.addTemplate("r", "{% for i in range(3) %}{{ i }}{% endfor %}"
            ~ "{% macro f(n) %}{% if n <= 1 %}1{% else %}{{ n * f(n - 1)|int }}{% endif %}{% endmacro %}"
            ~ "{{ f(5) }} {{ -2 ** 2 }} {{ 2 ** -1 }} {{ \"ab\" * 2 }} {{ 1 < 2 < 3 }} {{ 0 or \"x\" }}");
    assert(e.render("r", null) == "012120 4 0.5 abab True x");
}
