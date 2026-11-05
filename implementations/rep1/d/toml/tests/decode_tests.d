module decode_tests;

import std.exception : assertThrown;
import toml;

private string dec(string doc) { return tomlToTaggedJson(doc); }

private string scalarJson(string type, string value)
{
    return `{"a":{"type":"` ~ type ~ `","value":"` ~ value ~ `"}}`;
}

unittest // scalars
{
    assert(dec("a = 42") == scalarJson("integer", "42"));
    assert(dec("a = -0") == scalarJson("integer", "0"));
    assert(dec("a = 0xDEAD_beef") == scalarJson("integer", "3735928559"));
    assert(dec("a = 0o755") == scalarJson("integer", "493"));
    assert(dec("a = 0b1101") == scalarJson("integer", "13"));
    assert(dec("a = 1_000") == scalarJson("integer", "1000"));
    assert(dec("a = -9223372036854775808") == scalarJson("integer", "-9223372036854775808"));
    assert(dec("a = true") == scalarJson("bool", "true"));
    assert(dec(`a = "x\ty"`) == `{"a":{"type":"string","value":"x\ty"}}`);
    assert(dec("a = 'C:\\x'") == scalarJson("string", `C:\\x`));
}

unittest // floats
{
    assert(dec("a = 3.1415") == scalarJson("float", "3.1415000000000002e+00"));
    assert(dec("a = -0.0") == scalarJson("float", "-0.0000000000000000e+00"));
    assert(dec("a = 6.626e-34") == scalarJson("float", "6.6259999999999998e-34"));
    assert(dec("a = 1e400") == scalarJson("float", "inf"));
    assert(dec("a = -nan") == scalarJson("float", "nan"));
    assert(dec("a = 5e-324") == scalarJson("float", "4.9406564584124654e-324"));
    assert(dec("a = 1_0.2_5e0_1") == scalarJson("float", "1.0250000000000000e+02"));
}

unittest // date-times
{
    assert(dec("a = 1987-07-05 17:45:00z") == scalarJson("datetime", "1987-07-05T17:45:00Z"));
    assert(dec("a = 1987-07-05T17:45:56.600+08:00") == scalarJson("datetime", "1987-07-05T17:45:56.6+08:00"));
    assert(dec("a = 1979-05-27t07:32:00-00:00") == scalarJson("datetime", "1979-05-27T07:32:00Z"));
    assert(dec("a = 1979-05-27 # c") == scalarJson("date-local", "1979-05-27"));
    assert(dec("a = 07:32:00.000") == scalarJson("time-local", "07:32:00"));
    assert(dec("a = 2024-02-29T00:00:00") == scalarJson("datetime-local", "2024-02-29T00:00:00"));
}

unittest // strings
{
    assert(dec("a = \"\"\"\nx\\\n   y\"\"\"") == scalarJson("string", "xy"));
    assert(dec("a = '''\r\nl1\r\nl2'''") == scalarJson("string", `l1\nl2`));
    assert(dec(`a = """q""""`) == scalarJson("string", `q\"`));
    assert(dec(`a = "\u00e9\U0001F600"`) == `{"a":{"type":"string","value":"é😀"}}`);
    assert(dec(`a = "\u0000"`) == scalarJson("string", `\u0000`));
}

unittest // tables
{
    assert(dec("") == "{}");
    assert(dec("a.b = 1\na.c = 2") ==
        `{"a":{"b":{"type":"integer","value":"1"},"c":{"type":"integer","value":"2"}}}`);
    assert(dec("[[f]]\nn=1\n[f.p]\nx=1\n[[f]]\nn=2") ==
        `{"f":[{"n":{"type":"integer","value":"1"},"p":{"x":{"type":"integer","value":"1"}}},`
        ~ `{"n":{"type":"integer","value":"2"}}]}`);
    assert(dec("a = { b = [\n1,\n], c.d = 2 }") ==
        `{"a":{"b":[{"type":"integer","value":"1"}],"c":{"d":{"type":"integer","value":"2"}}}}`);
    assert(dec("[x]\na.b = 1\n[x.a.c]\nd = 1") !is null);
}

unittest // keys sort by code point
{
    assert(dec("\"é\" = 1\na = 2\nA = 3\n\"\" = 4") ==
        `{"":{"type":"integer","value":"4"},"A":{"type":"integer","value":"3"},`
        ~ `"a":{"type":"integer","value":"2"},"é":{"type":"integer","value":"1"}}`);
}

unittest // invalid documents
{
    immutable bad = [
        "a = ", "a = 01", "a = +0x1", "a = 0xFFFFFFFFFFFFFFFF", "a = 1__0", "a = 1_",
        "a = .5", "a = 5.", "a = 1e", "a = TRUE", "a = 1987-7-05", "a = 1979-02-30",
        "a = 1979-05-27T25:00:00", "a = 17:45", "a = 0000-01-01", "a = 12:00:60",
        "a = 1 b = 2", "a = 1\na = 2", "[a]\n[a]", "a.b = 1\n[a]", "[a]\nb=1\n[a.b]",
        "a = [1,,2]", "a = [,1]", "a = {b=1,}", "a = {b=1\n}", "a = {}\n[a.b]", "a = {b=1}\na.c = 2",
        "[fruit]\napple.color = 1\n[fruit.apple]", "a = [1]\n[[a]]", "[ [a] ]", "[[a] ]",
        "a = \"\\x\"", "a = \"\\ud800\"", "a = \"\\U00110000\"", "a = \"x\ny\"", "a = 'x\ny'",
        "a = \"\"\"x\"\"\"\"\"\"", "a = \"x\x01\"", "# c\x7f", "a = 1\rb = 2", "a = \"\r\"",
        "\xEF\xBB\xBFa = 1", "a = \"\xff\"", "a = \"\xed\xa0\x80\"", "a = \"\xc0\x80\"",
        "a = \u0661", "\"\"\"a\"\"\" = 1", "a = \"\"\"x\\ y\"\"\"", "a = 0X1", "a = inf2", "a = Inf",
    ];
    foreach (d; bad)
        assertThrown!TomlException(parse(d), d);
}
