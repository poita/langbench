module tests.test_roundtrip;

import tests.helpers;
import toml;

unittest // canonical encoding
{
    auto tree = fromTaggedJson(`{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer",
        "value":"8001"},{"type":"integer","value":"8002"}]},"dob":{"type":"datetime",
        "value":"1979-05-27T07:32:00-08:00"},"fruit":[{"name":{"type":"string","value":"apple"}},
        {"name":{"type":"string","value":"banana"}}],"name":{"type":"string","value":"Tom"}}`);
    assert(toToml(tree) ==
        "dob = 1979-05-27T07:32:00-08:00\nname = \"Tom\"\n\n[db]\nenabled = true\nports = [8001, 8002]\n\n"
        ~ "[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n");
}

unittest // empty containers, key quoting and string escapes
{
    assert(toToml(fromTaggedJson("{}")) == "\n");
    assert(toToml(fromTaggedJson(`{"a":{}}`)) == "[a]\n");
    assert(toToml(fromTaggedJson(`{"a":{"b":{}}}`)) == "[a]\n\n[a.b]\n");
    assert(toToml(fromTaggedJson(`{"a":[]}`)) == "a = []\n");
    assert(toToml(fromTaggedJson(`{"a":[{},{"type":"integer","value":"1"}]}`)) ==
        "a = [{}, 1]\n");
    assert(toToml(fromTaggedJson(`{"a b":{"type":"string","value":"q\"\\\u0001\u007f\n"}}`)) ==
        "\"a b\" = \"q\\\"\\\\\\u0001\\u007f\\n\"\n");
    assert(toToml(fromTaggedJson(`{"":{"type":"integer","value":"1"}}`)) == "\"\" = 1\n");
}

unittest // a table with keys "type" and "value" is still a table
{
    auto t = fromTaggedJson(`{"type":{"type":"string","value":"a"},"value":{"type":"string","value":"b"}}`);
    assert(t.isTable);
    assert(toToml(t) == "type = \"a\"\nvalue = \"b\"\n");
}

unittest // JSON reader handles whitespace and escapes
{
    auto t = fromTaggedJson(" { \"k\\u00e9\" : { \"value\" : \"\\ud83d\\ude00\" , \"type\" : \"string\" } } ");
    assert(t["ké"].asString == "😀");
}

unittest // decode(encode(x)) == x
{
    foreach (doc; [
        "a = 1\n[b]\nc = 'x'\n[[d]]\ne = [1, 2.5, 'z']\n[[d]]\nf = {g = 1979-05-27}\n",
        "\"quoted key\" = \"line\\nbreak\"\n[x.y.z]\n",
        "f = [inf, -inf, nan, -0.0, 1e300]\n",
        "t = 07:32:00.123\nd = 1979-05-27T07:32:00+05:30\n",
    ])
    {
        auto json = toTaggedJson(parseToml(doc));
        auto again = toTaggedJson(parseToml(toToml(fromTaggedJson(json))));
        assert(json == again, doc);
    }
}
