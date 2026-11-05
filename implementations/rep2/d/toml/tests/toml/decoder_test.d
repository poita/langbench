/// Unit tests for the decoder.
module toml.decoder_test;

import toml;

private string json(string doc) => toTaggedJson(parseToml(doc));

private bool rejects(string doc)
{
    try
    {
        parseToml(doc);
        return false;
    }
    catch (TomlException)
        return true;
}

unittest // empty document and simple scalars
{
    assert(json("") == "{}");
    assert(json("a = 1") == `{"a":{"type":"integer","value":"1"}}`);
    assert(json("a = true\nb = 'x'") == `{"a":{"type":"bool","value":"true"},"b":{"type":"string","value":"x"}}`);
}

unittest // integers in every base
{
    assert(parseToml("a = 0xDEAD_beef")["a"].integer == 0xDEADBEEF);
    assert(parseToml("a = 0o17")["a"].integer == 15);
    assert(parseToml("a = 0b1010")["a"].integer == 10);
    assert(parseToml("a = -9223372036854775808")["a"].integer == long.min);
    assert(parseToml("a = 9223372036854775807")["a"].integer == long.max);
    assert(parseToml("a = -0")["a"].text == "0");
    assert(rejects("a = 9223372036854775808"));
    assert(rejects("a = 0xFFFFFFFFFFFFFFFF"));
    assert(rejects("a = 01"));
    assert(rejects("a = 1__0"));
    assert(rejects("a = _1"));
    assert(rejects("a = -0x1"));
    assert(rejects("a = 0X1"));
}

unittest // floats
{
    assert(parseToml("a = 3.1415")["a"].text == "3.1415000000000002e+00");
    assert(parseToml("a = -0.0")["a"].text == "-0.0000000000000000e+00");
    assert(parseToml("a = 5e-324")["a"].text == "4.9406564584124654e-324");
    assert(parseToml("a = 1e400")["a"].text == "inf");
    assert(parseToml("a = -nan")["a"].text == "nan");
    assert(parseToml("a = 1_0.0_1e0_1")["a"].floating == 10.01e1);
    assert(rejects("a = .5"));
    assert(rejects("a = 5."));
    assert(rejects("a = 1.e2"));
    assert(rejects("a = 1e"));
    assert(rejects("a = INF"));
}

unittest // strings
{
    assert(parseToml(`a = "x\u00e9\U0001F600\n"`)["a"].str == "x\u00e9\U0001F600\n");
    assert(parseToml("a = \"\"\"\nline1\r\nline2 \\\n   cont\"\"\"")["a"].str == "line1\nline2 cont");
    assert(parseToml(`a = """x"""""`)["a"].str == `x""`);
    assert(parseToml("a = '''\n'raw\\'''")["a"].str == "'raw\\");
    assert(parseToml(`a = "\u0000"`)["a"].str == "\0");
    assert(rejects(`a = "\x"`));
    assert(rejects(`a = "\ud800"`));
    assert(rejects(`a = "\U00110000"`));
    assert(rejects("a = \"x\ny\""));
    assert(rejects("a = \"\x01\""));
    assert(rejects("a = \"\x7f\""));
    assert(rejects(`a = """x""""""`)); // six quotes
}

unittest // date-times are canonicalised textually
{
    assert(parseToml("a = 1987-07-05 17:45:00z")["a"].text == "1987-07-05T17:45:00Z");
    assert(parseToml("a = 1987-07-05t17:45:56.600+08:00")["a"].text == "1987-07-05T17:45:56.6+08:00");
    assert(parseToml("a = 1979-05-27T07:32:00-00:00")["a"].text == "1979-05-27T07:32:00Z");
    assert(parseToml("a = 07:32:00.000")["a"].text == "07:32:00");
    assert(parseToml("a = 1979-05-27 # c")["a"].kind == Kind.dateLocal);
    assert(parseToml("a = 1979-05-27T07:32:00")["a"].kind == Kind.datetimeLocal);
    assert(rejects("a = 2021-02-29"));
    assert(parseToml("a = 2020-02-29")["a"].kind == Kind.dateLocal);
    assert(rejects("a = 1900-02-29"));
    assert(rejects("a = 07:32"));
    assert(rejects("a = 07:32:60"));
    assert(rejects("a = 0000-01-01"));
    assert(rejects("a = 1987-7-05"));
    assert(rejects("a = \u0661\u0662\u0663\u0664-01-01"));
}

unittest // arrays and inline tables
{
    assert(json("a = [1, 'x', [true],\n # c\n ]") ==
        `{"a":[{"type":"integer","value":"1"},{"type":"string","value":"x"},[{"type":"bool","value":"true"}]]}`);
    assert(rejects("a = [1,,2]"));
    assert(rejects("a = [,1]"));
    assert(parseToml("a = {b = 1, c.d = 2}")["a"]["c"]["d"].integer == 2);
    assert(rejects("a = {b = 1,}"));
    assert(rejects("a = {b = 1,\n c = 2}"));
    assert(parseToml("a = {b = [\n1,\n]}")["a"]["b"].length == 1);
    assert(rejects("a = {b = 1}\n[a.c]"));
    assert(rejects("a = {b = 1}\na.c = 2"));
    assert(rejects("a = {b.c = 1}\n[a.b]"));
}

unittest // table rules
{
    assert(!rejects("[a]\n[a.b]\n[c]"));
    assert(!rejects("[a.b.c]\n[a]"));
    assert(rejects("[a]\n[a]"));
    assert(rejects("a = 1\n[a]"));
    assert(rejects("a = 1\na = 2"));
    assert(rejects("a.b = 1\n[a]"));
    assert(!rejects("a.b = 1\na.c = 2"));
    assert(!rejects("[fruit]\napple.color = 'red'\n[fruit.apple.texture]"));
    assert(rejects("[fruit]\napple.color = 'red'\n[fruit.apple]"));
    assert(rejects("[a]\nb = 1\n[a.b.c]"));
    assert(rejects("[a.b]\n[a]\nb.c = 1"));
    assert(rejects("[[a]]\n[a]"));
    assert(rejects("a = [1]\n[[a]]"));
    assert(rejects("[ [a] ]"));
    assert(!rejects("[[ a . b ]]"));

    auto d = parseToml("[[f]]\nn = 1\n[f.p]\nc = 2\n[[f.v]]\nx = 3\n[[f]]\nn = 4");
    assert(d["f"].length == 2);
    assert(d["f"][0]["p"]["c"].integer == 2);
    assert(d["f"][0]["v"][0]["x"].integer == 3);
    assert(d["f"][1]["n"].integer == 4);
    assert("p" !in d["f"][1]);
}

unittest // keys
{
    assert(parseToml(`"a" = 1`)["a"].integer == 1);
    assert(rejects("a = 1\n'a' = 2"));
    assert(parseToml("'' = 1")[""].integer == 1);
    assert(parseToml("a . b = 1")["a"]["b"].integer == 1);
    assert(parseToml("1234 = 1")["1234"].integer == 1);
    assert(rejects("\"\"\"a\"\"\" = 1"));
    assert(rejects("é = 1"));
}

unittest // encoding, CR, BOM and comments
{
    assert(rejects("\xEF\xBB\xBFa = 1"));
    assert(rejects("a = \"\xff\""));
    assert(rejects("a = \"\xc0\x80\""));
    assert(rejects("a = \"\xed\xa0\x80\""));
    assert(rejects("a = 1\rb = 2"));
    assert(rejects("# comment \r\na = \"\r\""));
    assert(!rejects("a = 1\r\nb = 2\r\n"));
    assert(rejects("# \x01"));
    assert(rejects("# \x7f"));
    assert(!rejects("# é\ta"));
    assert(rejects("a = 1 b = 2"));
}
