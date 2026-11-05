/// Unit tests for the tagged-JSON writer and reader.
module toml.json_test;

import toml;

unittest // key order is by code point, escapes follow the spec
{
    auto d = parseToml("\"é\" = 1\na = 2\nA = 3\n\"\" = 4");
    assert(toTaggedJson(d) == `{"":{"type":"integer","value":"4"},"A":{"type":"integer","value":"3"},`
            ~ `"a":{"type":"integer","value":"2"},"é":{"type":"integer","value":"1"}}`);
    auto s = parseToml(`a = "\u0001\u007f\"\\\b\f\n\r\t"`);
    assert(toTaggedJson(s) == `{"a":{"type":"string","value":"\u0001` ~ "\x7f" ~ `\"\\\b\f\n\r\t"}}`);
}

unittest // reader accepts arbitrary whitespace and member order
{
    auto n = fromTaggedJson(` { "b" : { "value" : "1" , "type":"integer" } , "a" : [ ] } `);
    assert(n["b"].kind == Kind.integer);
    assert(n["b"].text == "1");
    assert(n["a"].isArray && n["a"].length == 0);
}

unittest // a table named type/value is still a table
{
    auto n = fromTaggedJson(`{"type":{"type":"string","value":"x"},"value":{"type":"string","value":"y"}}`);
    assert(n.isTable);
    assert(n["type"].str == "x");
}

unittest // JSON escapes
{
    auto n = fromTaggedJson(`{"k\u00e9":{"type":"string","value":"\ud83d\ude00\n\/"}}`);
    assert(n["k\u00e9"].str == "\U0001F600\n/");
}

unittest // malformed JSON throws
{
    import std.exception : assertThrown;

    assertThrown!TomlException(fromTaggedJson(`{"a":`));
    assertThrown!TomlException(fromTaggedJson(`[1]`));
}
