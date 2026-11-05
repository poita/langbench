module tests.test_json;

import std.exception : assertThrown;
import jq;

private string rt(string s) { return toJson(parseJson(s)); }

unittest // round trips preserve order and formatting
{
    assert(rt(` { "b" : [ 1 , 2.5 , -3 ] , "a" : null } `) == `{"b":[1,2.5,-3],"a":null}`);
    assert(rt(`[]`) == `[]`);
    assert(rt(`{}`) == `{}`);
    assert(rt(`"x"`) == `"x"`);
    assert(rt("\t\r\n true \n") == `true`);
}

unittest // string escapes
{
    assert(rt(`"a\"b\\c\/d\b\f\n\r\t"`) == `"a\"b\\c/d\b\f\n\r\t"`);
    assert(rt(`"é\u0001\u007F"`) == "\"é\\u0001\\u007f\"");
    assert(rt(`"😀"`) == `"😀"`);
    assert(rt(`"😀"`) == `"😀"`);
    assert(rt(`"<>&/"`) == `"<>&/"`);
}

unittest // numbers
{
    assert(rt(`0`) == `0`);
    assert(rt(`1000000000000`) == `1000000000000`);
    assert(rt(`9007199254740991`) == `9007199254740991`);
    assert(rt(`-9007199254740991`) == `-9007199254740991`);
    assert(rt(`0.125`) == `0.125`);
    assert(rt(`3086419725308.5`) == `3086419725308.5`);
    assert(rt(`0.001`) == `0.001`);
    assert(rt(`1e2`) == `100`);
    assert(rt(`12345.678901234`) == `12345.678901234`);
    double d;
    assert(scanNumber("-2.5", 0, d) == 4 && d == -2.5);
    assert(scanNumber("x", 0, d) == size_t.max);
    assert(scanNumber("1.", 0, d) == size_t.max);
}

unittest // keys are interned in parsed documents
{
    auto v = parseJson(`[{"k":1},{"k":2}]`);
    assert(v.arr.items[0].obj.keys[0] is v.arr.items[1].obj.keys[0]);
}

unittest // malformed input
{
    assertThrown!JsonException(parseJson(`{"a":}`));
    assertThrown!JsonException(parseJson(`[1,2`));
    assertThrown!JsonException(parseJson(`"abc`));
    assertThrown!JsonException(parseJson(`1 2`));
    assertThrown!JsonException(parseJson(``));
    assertThrown!JsonException(parseJson(`"\x"`));
}

unittest // buffer
{
    Buffer b;
    putString(b, "a\"\n");
    assert(b.text == `"a\"\n"`);
    b.clear();
    putNumber(b, 42);
    assert(b.text == "42");
}
