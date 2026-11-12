/// End-to-end tests: the full input format through `parseDocument` and `Environment`.
module spec_examples;

import jinjalite;

private string runDocument(string input)
{
    try
    {
        auto doc = parseDocument(input);
        auto env = new Environment;
        foreach (name; doc.names)
            env.addTemplate(name, doc.bodies[name]);
        return env.render(doc.names[0], doc.context);
    }
    catch (TemplateError e)
        return "error: " ~ kindName(e.kind);
}

unittest // unclosed `for` is detected when the template is loaded
{
    assert(runDocument("{\"user\": {\"name\": \"Ada\", \"tags\": [\"x\", \"y\"]}, \"n\": 3}\n--\n" ~
        "=== main\nHi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n" ~
        "{% if n > 2 %}big{% endif %}\n") == "error: syntax");
}

unittest // whitespace control, filters, if/elif and list printing
{
    assert(runDocument("{\"user\": {\"name\": \"Ada\", \"tags\": [\"x\", \"y\"]}, \"n\": 3}\n--\n" ~
        "=== main\nHi {{ user.name|upper }}!\n{% for t in user.tags -%}\n  {{ loop.index }}. {{ t }}\n" ~
        "{% endfor -%}\n{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %}" ~
        " {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, \"s\"] }}\n") == "Hi ADA!\n1. x\n2. y\nbig 3.5 3 [3, 's']");
}

unittest // inheritance, super(), macros across templates, include
{
    assert(runDocument("{\"title\": \"T\", \"items\": [3, 1, 2]}\n--\n" ~
        "=== page\n{% extends \"base\" %}\n{% set count = items|length %}\n" ~
        "{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}\n" ~
        "=== base\n{% macro item(v) %}#{{ v }}{% endmacro -%}\n<h1>{% block title %}{{ title }}{% endblock %}</h1>\n" ~
        "{% block body %}{{ count }} items{% endblock %}\n{% include \"footer\" %}\n" ~
        "=== footer\n-- {{ title|lower }} {{ missing|default(\"end\") }}\n") ==
        "<h1>T</h1>\n3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>\n-- t end");
}

unittest // attribute access on an undefined member is an error
{
    assert(runDocument("{\"a\": {\"b\": 1}}\n--\n=== main\n{{ a.b }}{{ a.c.d }}\n") == "error: undefined");
}

unittest // float printing
{
    assert(runDocument("{}\n--\n=== main\n{{ 0.1 + 0.2 }} {{ 1e16 if false }}\n") == "error: syntax");
    assert(runDocument("{\"x\": 1e16, \"y\": 0.00001, \"z\": 2.5}\n--\n=== main\n{{ x }} {{ y }} {{ z * 2 }} {{ 10 ** 15 / 1 }}\n")
        == "1e+16 1e-05 5.0 1000000000000000.0");
}

unittest // dict printing and iteration order follow the JSON member order
{
    assert(runDocument("{\"d\": {\"b\": [1, {\"k\": \"it's\"}], \"a\": null}}\n--\n=== main\n{{ d }}\n")
        == "{'b': [1, {'k': \"it's\"}], 'a': None}");
}
