module encode_tests;

import std.exception : assertThrown;
import toml;

private string enc(string json) { return taggedJsonToToml(json); }

unittest // spec example
{
    auto got = enc(`{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},`
        ~ `{"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},`
        ~ `"fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],`
        ~ `"name":{"type":"string","value":"Tom"}}`);
    assert(got == "dob = 1979-05-27T07:32:00-08:00\nname = \"Tom\"\n\n[db]\nenabled = true\n"
        ~ "ports = [8001, 8002]\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n");
}

unittest // empty and nested headers
{
    assert(enc("{}") == "\n");
    assert(enc(` { "a" : { "b" : { } } } `) == "[a]\n\n[a.b]\n");
}

unittest // mixed arrays, inline tables, empty arrays
{
    assert(enc(`{"a":[{"x":{"type":"integer","value":"1"}},{"type":"integer","value":"2"}],"b":[],"c":[[],[{"type":"bool","value":"true"}]]}`)
        == "a = [{x = 1}, 2]\nb = []\nc = [[], [true]]\n");
}

unittest // key and string quoting
{
    assert(enc(`{"a b":{"type":"string","value":"q\"\\\u0001\u007f\n\u00e9"},"":{"type":"integer","value":"1"}}`)
        == "\"\" = 1\n\"a b\" = \"q\\\"\\\\\\u0001\\u007f\\n\u00e9\"\n");
    assert(renderKey("ab-_9") == "ab-_9");
    assert(renderKey("") == `""`);
}

unittest // a table whose keys are "type" and "value"
{
    auto n = fromTaggedJson(`{"type":{"type":"string","value":"a"},"value":{"type":"string","value":"b"}}`);
    assert(n.isTable);
    assert(n["type"].asString == "a");
}

unittest // round trip
{
    immutable doc = "a = 1.5\nb = [1, \"x\", {c = 2}]\nd.e = 1979-05-27\n[[t]]\nx = 'y'\n[t.u]\nv = false\n";
    auto json = tomlToTaggedJson(doc);
    auto toml1 = taggedJsonToToml(json);
    assert(tomlToTaggedJson(toml1) == json);
}

unittest // JSON escapes
{
    auto n = fromTaggedJson(`{"k\u0041":{"type":"string","value":"\ud83d\ude00\/"}}`);
    assert(n["kA"].asString == "😀/");
    assertThrown!TomlException(fromTaggedJson(`{"a":`));
}
