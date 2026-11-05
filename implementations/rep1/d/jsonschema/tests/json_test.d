module json_test;

import std.exception : assertThrown;

import jsonschema.json;

unittest // scalars
{
    assert(parseJson("null").isNull);
    assert(parseJson("true").boolean);
    assert(!parseJson("false").boolean);
    assert(parseJson(" 12 ").number.isInteger);
    assert(parseJson(`"hi"`).str == "hi");
}

unittest // string escapes
{
    assert(parseJson(`"a\nb\t\"\\\/"`).str == "a\nb\t\"\\/");
    assert(parseJson(`"é"`).str == "é");
    assert(parseJson(`"💩"`).str == "💩");
    assert(codePointLength(parseJson(`"💩"`).str) == 1);
    assert(codePointLength("é") == 1);
    assert(codePointLength("é") == 2);
}

unittest // containers
{
    auto v = parseJson(`{"a":[1,2,{"b":null}],"c":"d"}`);
    assert(v.isObject);
    assert(v.object.length == 2);
    assert(v.object.members[0].key == "a");
    auto a = "a" in v;
    assert(a !is null && a.array.length == 3);
    assert(("missing" in v) is null);
    assert(parseJson("[]").array.length == 0);
    assert(parseJson("{}").object.length == 0);
}

unittest // large objects use the index
{
    string text = "{";
    foreach (i; 0 .. 50)
    {
        import std.conv : to;

        text ~= (i ? "," : "") ~ `"k` ~ i.to!string ~ `":` ~ i.to!string;
    }
    text ~= "}";
    auto v = parseJson(text);
    assert(v.object.find("k37") !is null);
    assert(v.object.find("k99") is null);
}

unittest // equality (section 3.4)
{
    assert(jsonEqual(parseJson("1"), parseJson("1.0")));
    assert(!jsonEqual(parseJson("true"), parseJson("1")));
    assert(!jsonEqual(parseJson("false"), parseJson("0")));
    assert(!jsonEqual(parseJson(`"1"`), parseJson("1")));
    assert(jsonEqual(parseJson(`{"a":1,"b":2}`), parseJson(`{"b":2.0,"a":1}`)));
    assert(!jsonEqual(parseJson(`{"a":1}`), parseJson(`{"a":1,"b":2}`)));
    assert(!jsonEqual(parseJson("[1,2]"), parseJson("[2,1]")));
    assert(jsonHash(parseJson(`{"a":1,"b":2}`)) == jsonHash(parseJson(`{"b":2,"a":1}`)));
}

unittest // malformed input
{
    assertThrown!JsonException(parseJson("{"));
    assertThrown!JsonException(parseJson("[1,]"));
    assertThrown!JsonException(parseJson("01"));
    assertThrown!JsonException(parseJson(`"abc`));
    assertThrown!JsonException(parseJson("tru"));
    assertThrown!JsonException(parseJson("1 2"));
    assertThrown!JsonException(parseJson("1."));
}

unittest // round trip
{
    auto text = `{"a":[1,true,null,"x\n"],"b":{}}`;
    assert(toJson(parseJson(text)) == text);
}
