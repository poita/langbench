module tests.test_node;

import toml;

unittest // typed access to a parsed document
{
    auto doc = parseToml("title = 'x'\nn = 7\nf = 2.5\nb = true\n[t]\nl = [1, 2]\n[[arr]]\nk = 1\n");
    assert(doc["title"].asString == "x");
    assert(doc["n"].asLong == 7);
    assert(doc["f"].asDouble == 2.5);
    assert(doc["b"].asBool);
    assert(doc["t"]["l"].length == 2);
    assert(doc["t"]["l"][1].asLong == 2);
    assert(doc["arr"][0]["k"].asLong == 1);
    assert("n" in doc);
    assert(!("zzz" in doc));
}

unittest // errors
{
    import std.exception : assertThrown;
    auto doc = parseToml("a = 1");
    assertThrown!TomlException(doc["missing"]);
    assertThrown!TomlException(doc["a"].asString);
    assertThrown!TomlException(parseToml("a = "));
}

unittest // building a tree by hand
{
    auto root = Node.newTable();
    root.members["name"] = Node.fromString("x");
    root.members["n"] = Node.fromLong(-3);
    root.members["ok"] = Node.fromBool(false);
    assert(toToml(root) == "n = -3\nname = \"x\"\nok = false\n");
}
