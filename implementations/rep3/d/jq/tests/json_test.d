module tests.json_test;

import jq;

private string roundTrip(string s) { return toJson(parseJson(s)); }

unittest // scalars and whitespace
{
    assert(roundTrip(" null ") == "null");
    assert(roundTrip("\n\ttrue\r\n") == "true");
    assert(roundTrip("false") == "false");
    assert(roundTrip("-12") == "-12");
    assert(roundTrip("[ 1 , 2 ]") == "[1,2]");
    assert(roundTrip(`{ "a" : [ ] , "b" : { } }`) == `{"a":[],"b":{}}`);
}

unittest // numbers
{
    assert(roundTrip("1000000000000") == "1000000000000");
    assert(roundTrip("0.125") == "0.125");
    assert(roundTrip("3086419725308.5") == "3086419725308.5");
    assert(roundTrip("-2.5") == "-2.5");
    assert(roundTrip("12345678901234") == "12345678901234");
    assert(parseJson("1e2").num == 100);
    assert(parseJson("0.1").num == 0.1);
}

unittest // string escapes
{
    assert(parseJson(`"a\nb"`).str == "a\nb");
    assert(parseJson(`"é"`).str == "é");
    assert(parseJson(`"😀"`).str == "\U0001F600");
    assert(parseJson(`"\/\b\f\r\t\"\\"`).str == "/\b\f\r\t\"\\");
    assert(toJson(parseJson(`"\u0001\u007f\u001f"`)) == `"\u0001\u007f\u001f"`);
    assert(toJson(parseJson(`"</>&é"`)) == `"</>&é"`);
}

unittest // key order is document order
{
    assert(roundTrip(`{"z":1,"a":2,"m":3}`) == `{"z":1,"a":2,"m":3}`);
}

unittest // malformed input
{
    foreach (bad; ["", "[1,", "{\"a\"}", "tru", "[1 2]", "\"abc", "01x", "1 2"])
    {
        bool threw;
        try
            parseJson(bad);
        catch (ParseError)
            threw = true;
        assert(threw, bad);
    }
}

unittest // object with many keys uses the hash index
{
    string s = "{";
    foreach (i; 0 .. 100)
    {
        import std.conv : to;
        s ~= (i ? "," : "") ~ `"k` ~ i.to!string ~ `":` ~ i.to!string;
    }
    s ~= "}";
    auto v = parseJson(s);
    bool f;
    assert(v.obj.get("k77", f).num == 77 && f);
    v.obj.get("nope", f);
    assert(!f);
    assert(toJson(v) == s);
}
