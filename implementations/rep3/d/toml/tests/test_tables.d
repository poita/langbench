module tests.test_tables;

import tests.helpers;
import toml;

private enum one = scalar("integer", "1");
private enum two = scalar("integer", "2");

unittest // headers and dotted keys
{
    assert(decode("[a]\nb = 1\n[c.d]\ne = 2") == `{"a":{"b":` ~ one ~ `},"c":{"d":{"e":` ~ two ~ `}}}`);
    assert(decode("a.b.c = 1") == `{"a":{"b":{"c":` ~ one ~ `}}}`);
    assert(decode("a . b = 1\na.c = 2") == `{"a":{"b":` ~ one ~ `,"c":` ~ two ~ `}}`);
    assert(decode("[a.b.c]\n[a]\nx = 1") == `{"a":{"b":{"c":{}},"x":` ~ one ~ `}}`);
    assert(decode("[fruit]\napple.color = 1\n[fruit.apple.texture]\nx = 2") ==
        `{"fruit":{"apple":{"color":` ~ one ~ `,"texture":{"x":` ~ two ~ `}}}}`);
}

unittest // table redefinition errors
{
    foreach (bad; ["[a]\n[a]", "a = 1\na = 2", "[a]\nb = 1\n[a.b]", "a.b = 1\n[a]", "[x]\na.b = 1\n[x.a]",
                   "a = {}\n[a]", "[a]\nb.c = 1\n[a.b]", "a = 1\n[a.b]", "a = [1]\n[a.b]",
                   "[a.b.c]\nz = 1\n[a]\nb.c.t = 2", "a = [1]\n[[a]]", "[a]\n[[a]]", "[[a]]\n[a]"])
        assert(rejects(bad), bad);
}

unittest // arrays of tables
{
    assert(decode("[[a]]\nx = 1\n[[a]]\nx = 2") == `{"a":[{"x":` ~ one ~ `},{"x":` ~ two ~ `}]}`);
    assert(decode("[[a]]\n[a.b]\nx = 1\n[[a]]\n[[a.c]]\ny = 2") ==
        `{"a":[{"b":{"x":` ~ one ~ `}},{"c":[{"y":` ~ two ~ `}]}]}`);
    assert(decode("[[ a . b ]]") == `{"a":{"b":[{}]}}`);
    assert(rejects("[ [a] ]"));
    assert(rejects("[[a] ]"));
    assert(rejects("[ [a]]"));
}

unittest // inline tables
{
    assert(decode("a = {b = 1, c.d = 2}") == `{"a":{"b":` ~ one ~ `,"c":{"d":` ~ two ~ `}}}`);
    assert(decode("a = {}") == `{"a":{}}`);
    assert(decode("a = {b = [\n1,\n]}") == `{"a":{"b":[` ~ one ~ `]}}`);
    foreach (bad; ["a = {b = 1,}", "a = {\nb = 1}", "a = {b = 1\n}", "a = {b = 1}\na.c = 2", "a = {b = {}}\n[a.b]",
                   "a = {b.c = 1}\n[a.b]", "a = {b = 1, b = 2}", "a = {b = 1 c = 2}", "a = {,}"])
        assert(rejects(bad), bad);
}

unittest // arrays
{
    assert(decode("a = [1, 2, ]") == `{"a":[` ~ one ~ `,` ~ two ~ `]}`);
    assert(decode("a = [\n # c\n 1, # d\n 2\n]") == `{"a":[` ~ one ~ `,` ~ two ~ `]}`);
    assert(decode("a = [1, 'x', [true]]") ==
        `{"a":[` ~ one ~ `,` ~ scalar("string", "x") ~ `,[` ~ scalar("bool", "true") ~ `]]}`);
    foreach (bad; ["a = [,]", "a = [1,,2]", "a = [,1]", "a = [1 2]", "a = [1", "a = ["])
        assert(rejects(bad), bad);
}

unittest // document structure
{
    assert(decode("") == "{}");
    assert(decode("# only a comment") == "{}");
    assert(decode("a = 1\r\nb = 2\r\n") == `{"a":` ~ one ~ `,"b":` ~ two ~ `}`);
    foreach (bad; ["a = 1 b = 2", "a =", "= 1", "a = 1\r", "a = 1\rb = 2", "# c\rx", "\uFEFFa = 1",
                   "a = 1 # \x01", "a = 1 # \x7f", "a = \"\xff\"", "a = \"\xc0\x80\"", "a = \"\xed\xa0\x80\"",
                   "a b = 1", "a = 1 ]"])
        assert(rejects(bad), bad);
}

unittest // JSON output is sorted by code point and escapes control characters
{
    assert(decode("b = 1\nA = 2\n\"é\" = 1\na = 1") ==
        `{"A":` ~ two ~ `,"a":` ~ one ~ `,"b":` ~ one ~ `,"é":` ~ one ~ `}`);
    assert(decode("a = \"\\u0001\\u001f\\b\\f\"") ==
        `{"a":` ~ scalar("string", `\u0001\u001f\b\f`) ~ `}`);
}
