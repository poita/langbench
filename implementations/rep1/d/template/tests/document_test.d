module tests.document_test;

import jtemplate;

unittest // splitting the input into context and templates
{
    auto doc = parseDocument("{\"a\": 1}\n--\n=== main\nHello {{ a }}\n=== other\nx\n\n=== last\ny\n");
    assert(doc.names == ["main", "other", "last"]);
    assert(doc.sources["main"] == "Hello {{ a }}");
    assert(doc.sources["other"] == "x\n");
    assert(doc.sources["last"] == "y");
    assert(doc.context.dict.find("a").i == 1);
}

unittest // a multi-line JSON context
{
    auto doc = parseDocument("{\n  \"a\": [1,\n 2]\n}\n--\n=== main\nx");
    assert(doc.context.dict.find("a").list.length == 2);
    assert(doc.sources["main"] == "x");
}

unittest // empty bodies
{
    assert(parseDocument("{}\n--\n=== main\n\n").sources["main"] == "");
    assert(parseDocument("{}\n--\n=== main\n").sources["main"] == "");
    auto d = parseDocument("{}\n--\n=== a\n=== b\nx");
    assert(d.sources["a"] == "" && d.sources["b"] == "x");
}

unittest // layout errors are syntax errors
{
    foreach (bad; ["{}\n=== main\nx", "[1]\n--\n=== main\nx", "{}\n--\n"])
    {
        bool threw;
        try parseDocument(bad);
        catch (TemplateError e) threw = e.kind == ErrorKind.syntax;
        assert(threw, bad);
    }
}

unittest // renderDocument produces the exact CLI output
{
    assert(renderDocument("{\"n\": 3}\n--\n=== main\nn={{ n }}") == "n=3\n");
    assert(renderDocument("{}\n--\n=== main\n{{ x }}") == "error: undefined\n");
    assert(renderDocument("{}\n--\n=== main\n{% if %}") == "error: syntax\n");
    assert(renderDocument("{}\n--\n=== main\n{{ 1|nope }}") == "error: filter\n");
    assert(renderDocument("{}\n--\n=== main\n{% include 'x' %}") == "error: template\n");
    assert(renderDocument("{}\n--\n=== main\n{{ 1 + 'a' }}") == "error: type\n");
}
