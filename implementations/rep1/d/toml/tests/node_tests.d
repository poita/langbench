module node_tests;

import toml;

unittest // typed accessors
{
    auto d = parse("i = -5\nf = 2.5\nb = true\ns = 'x'\na = [1, 2]\n");
    assert(d["i"].asInteger == -5);
    assert(d["f"].asFloat == 2.5);
    assert(d["b"].asBool);
    assert(d["s"].asString == "x");
    assert(d["a"].length == 2 && d["a"][1].asInteger == 2);
    assert(d.sortedKeys == ["a", "b", "f", "i", "s"]);
    assert(("zz" in d) is null);
}

unittest // error carries a line number
{
    try
    {
        parse("a = 1\nb = \n");
        assert(false);
    }
    catch (TomlException e)
        assert(e.line == 2);
}
