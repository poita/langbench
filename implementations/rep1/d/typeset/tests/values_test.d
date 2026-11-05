module tests.values_test;

import typeset.values;

unittest // length literals
{
    long v;
    assert(parseLength("2.5pt", v) && v == 2500);
    assert(parseLength("0.5pt", v) && v == 500);
    assert(parseLength("1.5mm", v) && v == 4252);
    assert(parseLength("-6pt", v) && v == -6000);
    assert(parseLength("734", v) && v == 734);
    assert(parseLength("1in", v) && v == 72000);
    assert(parseLength("1pc", v) && v == 12000);
    assert(parseLength("2cm", v) && v == 56700);
}

unittest // malformed lengths
{
    long v;
    assert(!parseLength("", v));
    assert(!parseLength("+1", v));
    assert(!parseLength("1.", v));
    assert(!parseLength(".5", v));
    assert(!parseLength("1.2345", v));
    assert(!parseLength("20px", v));
    assert(!parseLength("1 pt", v));
}

unittest // integers
{
    long v;
    assert(parseInteger("42", v) && v == 42);
    assert(parseInteger("-7", v) && v == -7);
    assert(!parseInteger("+7", v));
    assert(!parseInteger("", v));
    assert(!parseInteger("1.5", v));
}

unittest // assignment lines
{
    auto a = parseAssignment("  page-width =  200pt  ", true);
    assert(a.ok && a.key("  page-width =  200pt  ") == "page-width");
    assert(a.value("  page-width =  200pt  ") == "200pt");
    assert(!parseAssignment("Page = 1", true).ok);
    assert(!parseAssignment("novalue", true).ok);
    assert(parseAssignment("k=", true).ok);
}

unittest // columns count Unicode scalar values
{
    assert(columnAt("héllo", 0) == 1);
    assert(columnAt("héllo", 3) == 3); // after 'h' and 'é'
}

unittest // line splitting ignores the final newline
{
    assert(splitLines("a\nb\n") == ["a", "b"]);
    assert(splitLines("a\n\nb") == ["a", "", "b"]);
    assert(splitLines("").length == 0);
}
