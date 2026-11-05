module test_json;

import std.exception : assertThrown;
import jq;

private string rt(string s)
{
    return toJson(parseJson(s));
}

unittest // scalars
{
    assert(rt("null") == "null");
    assert(rt(" true ") == "true");
    assert(rt("false") == "false");
    assert(rt("0") == "0");
    assert(rt("-12") == "-12");
    assert(rt("1.5") == "1.5");
    assert(rt("0.125") == "0.125");
    assert(rt("3086419725308.5") == "3086419725308.5");
    assert(rt("1000000000000") == "1000000000000");
}

unittest // numbers are correctly rounded doubles
{
    assert(parseJson("0.1").num == 0.1);
    assert(parseJson("123456789012345678").num == 123456789012345678.0);
    assert(parseJson("1e2").num == 100);
    assert(parseJson("2.5E-1").num == 0.25);
    assert(parseJson("0.30000000000000004").num == 0.1 + 0.2);
    assert(toJson(Value.number(0.1 + 0.2)) == "0.30000000000000004");
}

unittest // containers and key order
{
    assert(rt(`{"b":1, "a" : [1 , 2,{"c":null}]}`) == `{"b":1,"a":[1,2,{"c":null}]}`);
    assert(rt("[]") == "[]");
    assert(rt("{}") == "{}");
    assert(rt("\t[ \r\n ]\n") == "[]");
}

unittest // string escapes
{
    assert(parseJson(`"a\"b\\c\/d\b\f\n\r\t"`).str == "a\"b\\c/d\b\f\n\r\t");
    assert(parseJson(`"éé"`).str == "éé");
    assert(parseJson(`"😀"`).str == "😀");
    assert(parseJson(`"héllo 😀"`).str == "héllo 😀");
}

unittest // string output escaping
{
    assert(toJson(Value.string_("a\"b\\c\n\r\t\b\f")) == `"a\"b\\c\n\r\t\b\f"`);
    assert(toJson(Value.string_("\x01\x1f\x7f")) == `"\u0001\u001f\u007f"`);
    assert(toJson(Value.string_("/<>&é😀")) == "\"/<>&é😀\"");
}

unittest // duplicate keys: last value wins, first position kept
{
    assert(rt(`{"a":1,"b":2,"a":3}`) == `{"a":3,"b":2}`);
}

unittest // object keys are interned by the parser
{
    auto v = parseJson(`[{"id":1},{"id":2}]`);
    assert(v.items[0].obj.entries[0].key is v.items[1].obj.entries[0].key);
}

unittest // malformed input
{
    assertThrown!JsonException(parseJson(""));
    assertThrown!JsonException(parseJson("[1,"));
    assertThrown!JsonException(parseJson("{\"a\" 1}"));
    assertThrown!JsonException(parseJson("tru"));
    assertThrown!JsonException(parseJson("[1] 2"));
    assertThrown!JsonException(parseJson(`"abc`));
    assertThrown!JsonException(parseJson(`"\x"`));
    assertThrown!JsonException(parseJson("01"));
    assertThrown!JsonException(parseJson("1."));
}

unittest // number formatting
{
    assert(toJson(Value.number(3)) == "3");
    assert(toJson(Value.number(-0.0)) == "0");
    assert(toJson(Value.number(9007199254740991)) == "9007199254740991");
    assert(toJson(Value.number(0.001)) == "0.001");
    assert(toJson(Value.number(2.5)) == "2.5");
    assert(toJson(Value.number(-1234.5678)) == "-1234.5678");
}
