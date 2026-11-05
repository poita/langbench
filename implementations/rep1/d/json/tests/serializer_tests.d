module serializer_tests;

import canonjson;
import helpers;

unittest // whitespace removal and structure
{
    assert(canon(`{ "a" : [ 1 , 2 , { } , [ ] ] }`) == `{"a":[1,2,{},[]]}`);
    assert(canon("[\n1,\n2\n]") == "[1,2]");
}

unittest // key sorting and duplicates
{
    assert(canon(`{"b":1,"a":2,"c":3}`) == `{"a":2,"b":1,"c":3}`);
    assert(canon(`{"a":1,"b":2,"a":3}`) == `{"a":3,"b":2}`);
    assert(canon(`{"a":1,"a":2,"a":3,"a":4}`) == `{"a":4}`);
    assert(canon(`{"a":1,"\u0061":2}`) == `{"a":2}`);          // equal after decoding
    assert(canon(`{"a":{"x":1},"a":{"y":2}}`) == `{"a":{"y":2}}`); // no merging
    assert(canon(`{"b":null,"a":1,"b":2,"a":3}`) == `{"a":3,"b":2}`);
    assert(canon(`{"":1,"a":2,"":3}`) == `{"":3,"a":2}`);
}

unittest // nested objects are sorted too (handle stack reuse)
{
    assert(canon(`{"z":{"b":1,"a":2},"y":{"d":{"f":1,"e":2},"c":3},"x":1}`)
        == `{"x":1,"y":{"c":3,"d":{"e":2,"f":1}},"z":{"a":2,"b":1}}`);
    assert(canon(`[{"b":1,"a":2},{"d":3,"c":4}]`) == `[{"a":2,"b":1},{"c":4,"d":3}]`);
}

unittest // UTF-16 ordering
{
    assert(canon("{\"\\uE000\":1,\"\U0001F600\":2,\"\\uFFFF\":3,\"Z\":4}")
        == "{\"Z\":4,\"\U0001F600\":2,\"\uE000\":1,\"\uFFFF\":3}");
    assert(canon("{\"a\\u0000\":1,\"a\":2,\"aa\":3,\"\":4}") == "{\"\":4,\"a\":2,\"a\\u0000\":1,\"aa\":3}");
}

unittest // string escaping
{
    assert(canon(`"\u0041\/"`) == `"A/"`);
    assert(canon(`"\u0000\u001f\u0008\u000c\u000a\u000d\u0009"`) == `"\u0000\u001f\b\f\n\r\t"`);
    assert(canon(`"\"\\"`) == `"\"\\"`);
    assert(canon("\"\u007f\"") == "\"\u007f\"");
    assert(canon(`"\u007f\u2028"`) == "\"\u007f\u2028\"");
    assert(canon(`"\uD83D\uDE00"`) == "\"\U0001F600\"");
    assert(canon(`"\u00e9\u20AC"`) == "\"\u00e9\u20ac\"");
    assert(canon(`{"\u0001":"\u001F"}`) == `{"\u0001":"\u001f"}`);
    // long strings with escapes at various positions (exercises run copying)
    assert(canon(`"0123456789abcdef\n0123456789abcdef\\0123"`) == `"0123456789abcdef\n0123456789abcdef\\0123"`);
}

unittest // numbers are echoed textually
{
    assert(canon("1.0") == "1.0");
    assert(canon("1.50") == "1.50");
    assert(canon("1E5") == "1e5");
    assert(canon("1e+05") == "1e5");
    assert(canon("1e-007") == "1e-7");
    assert(canon("1e-0") == "1e0");
    assert(canon("1E+00") == "1e0");
    assert(canon("-0.0") == "-0.0");
    assert(canon("-0") == "-0");
    assert(canon("0e0") == "0e0");
    assert(canon("2.5E-000789") == "2.5e-789");
    assert(canon("123456789012345678901234567890") == "123456789012345678901234567890");
    assert(canon("-1.250000000000000000000000000000000001E+0010") == "-1.250000000000000000000000000000000001e10");
    assert(canon("1e0000000000000000000000000000000000000000000000001") == "1e1");
    assert(canon("1e-0000000000000000000000000000000000000000000000000") == "1e0");
}

unittest // spec worked examples
{
    assert(canon(`{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }`) == `{"a":"héllo/","b":null}`);
    assert(canon("[\"\U0001F600\", -0, 1e-007, 0.0, 1e-0, \"tab\\tquote\\\"nul\\u0000 A\\u0041\"]")
        == "[\"\U0001F600\",-0,1e-7,0.0,1e0,\"tab\\tquote\\\"nul\\u0000 AA\"]");
    assert(canon(`[1, 2, ]`) == "invalid");
}

unittest // a tree built by hand serializes the same way
{
    auto a = Value.makeObject([
        Member(cast(const(ubyte)[]) "b", Value.makeNumber(cast(const(ubyte)[]) "1")),
        Member(cast(const(ubyte)[]) "a", Value.makeArray([Value.literal(Kind.null_), Value.makeString(cast(const(ubyte)[]) "x\n")])),
    ]);
    assert(cast(string) toCanonical(a) == `{"a":[null,"x\n"],"b":1}`);
}

unittest // writeString and ByteBuffer
{
    ByteBuffer b;
    writeString(b, cast(const(ubyte)[]) "a\"b\x01");
    assert(b.data == cast(const(ubyte)[]) `"a\"b\u0001"`);
}

unittest // library entry points
{
    assert(canonicalize(`{ "a" : 1 }`) == `{"a":1}`);
    ubyte[] o;
    assert(!tryCanonicalize(cast(const(ubyte)[]) "[", o));
    assert(tryCanonicalize(cast(const(ubyte)[]) "[1]", o) && o == cast(const(ubyte)[]) "[1]");
    bool threw;
    try canonicalize("{");
    catch (ParseException) threw = true;
    assert(threw);
}

unittest // large objects: sort + dedup agree with a reference
{
    import std.algorithm : map, sort;
    import std.array : appender, array;
    import std.conv : to;
    import std.range : iota;

    // keys 0..999 inserted in a scrambled order, each twice (second value wins)
    auto src = appender!string("{");
    foreach (round; 0 .. 2)
        foreach (i; 0 .. 1000)
        {
            immutable k = (i * 7919) % 1000;
            if (src.data.length > 1)
                src ~= ",";
            src ~= `"k` ~ to!string(k) ~ `":` ~ to!string(round * 10000 + k);
        }
    src ~= "}";
    auto expected = iota(0, 1000).map!(k => "k" ~ to!string(k)).array;
    expected.sort();
    string want = "{";
    foreach (j, k; expected)
        want ~= (j ? "," : "") ~ `"` ~ k ~ `":` ~ to!string(10000 + to!int(k[1 .. $]));
    want ~= "}";
    assert(canon(src.data) == want);
}
