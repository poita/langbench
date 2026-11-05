/// Unit tests for the canonical TOML encoder.
module toml.encoder_test;

import toml;

private string enc(string json) => toToml(fromTaggedJson(json));

unittest // the worked example
{
    auto input = `{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},`
        ~ `{"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},`
        ~ `"fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],`
        ~ `"name":{"type":"string","value":"Tom"}}`;
    assert(enc(input) == "dob = 1979-05-27T07:32:00-08:00\nname = \"Tom\"\n\n[db]\nenabled = true\n"
            ~ "ports = [8001, 8002]\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n");
}

unittest // empty root, empty containers, headers on first line
{
    assert(enc("{}") == "\n");
    assert(enc(`{"a":{}}`) == "[a]\n");
    assert(enc(`{"a":{"b":{}}}`) == "[a]\n\n[a.b]\n");
    assert(enc(`{"a":[]}`) == "a = []\n");
    assert(enc(`{"a":[{}]}`) == "[[a]]\n");
}

unittest // key quoting and string escapes
{
    assert(enc(`{"a b":{"type":"string","value":"q\"\\\u0001\u007f\u00e9"},"":{"type":"integer","value":"1"}}`)
            == "\"\" = 1\n\"a b\" = \"q\\\"\\\\\\u0001\\u007f\u00e9\"\n");
}

unittest // mixed arrays render inline, nested tables inline
{
    assert(enc(`{"a":[{"b":{"type":"integer","value":"1"}},{"type":"integer","value":"2"}]}`)
            == "a = [{b = 1}, 2]\n");
}

unittest // round trip: decode(encode(x)) == x
{
    auto doc = "a = 1.5\nb = 'x\\y'\nc = [1, [2], {d = 1979-05-27}]\n[t]\nu = 1\n[[t.v]]\nw = 07:32:00\n"
        ~ "[[t.v]]\n[t.v.sub]\nz = \"\\u0000\"\n";
    auto j = toTaggedJson(parseToml(doc));
    assert(toTaggedJson(parseToml(toToml(fromTaggedJson(j)))) == j);
}
