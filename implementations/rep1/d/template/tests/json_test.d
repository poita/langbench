module tests.json_test;

import jtemplate;

unittest // scalars
{
    assert(parseJson("12").kind == Kind.integer);
    assert(parseJson("-12").i == -12);
    assert(parseJson("1.0").kind == Kind.floating);
    assert(parseJson("1e2").kind == Kind.floating && parseJson("1e2").d == 100.0);
    assert(parseJson("true").kind == Kind.boolean && parseJson("true").i == 1);
    assert(parseJson("null").kind == Kind.none);
    assert(parseJson(`"hi"`).s == "hi");
}

unittest // integer limits
{
    assert(parseJson("9223372036854775807").i == long.max);
    assert(parseJson("-9223372036854775808").i == long.min);
    assert(parseJson("9223372036854775808").kind == Kind.floating);
}

unittest // string escapes
{
    assert(parseJson(`"a\nb\t\"\\\/"`).s == "a\nb\t\"\\/");
    assert(parseJson(`"é"`).s == "é");
    assert(parseJson(`"😀"`).s == "😀");
}

unittest // objects keep member order and lists keep element order
{
    auto v = parseJson(`{"z": 1, "a": [1, 2, {"k": null}], "m": {}}`);
    assert(v.kind == Kind.dict);
    assert(v.dict.keys == ["z", "a", "m"]);
    assert(v.dict.find("a").list.length == 3);
    assert(v.dict.find("m").dict.length == 0);
    assert(v.dict.find("missing") is null);
}

unittest // large objects use the hash index
{
    string text = "{";
    foreach (i; 0 .. 100)
    {
        import std.conv : to;
        text ~= (i ? "," : "") ~ `"k` ~ i.to!string ~ `":` ~ i.to!string;
    }
    auto v = parseJson(text ~ "}");
    assert(v.dict.length == 100);
    assert(v.dict.find("k77").i == 77);
    assert(v.dict.keys[3] == "k3");
}

unittest // invalid documents
{
    foreach (bad; ["", "{", "[1,", `{"a" 1}`, "nul", `"abc`, "1.", "01x", `{"a":1} x`])
    {
        bool threw;
        try parseJson(bad);
        catch (TemplateError) threw = true;
        assert(threw, bad);
    }
}
