module codec_test;

import std.exception : assertThrown;

import protowire;

private Codec make(string schema) @safe
{
    return new Codec(Schema.parse(schema));
}

private ubyte[] hex(string s) @safe
{
    ubyte[] r;
    foreach (i; 0 .. s.length / 2)
    {
        ubyte v = 0;
        foreach (c; s[2 * i .. 2 * i + 2])
            v = cast(ubyte)(v * 16 + (c <= '9' ? c - '0' : c - 'a' + 10));
        r ~= v;
    }
    return r;
}

private string toHex(const(ubyte)[] b) @safe
{
    static immutable digits = "0123456789abcdef";
    string r;
    foreach (x; b)
    {
        r ~= digits[x >> 4];
        r ~= digits[x & 15];
    }
    return r;
}

private enum spec = "message Inner { sint32 v = 1; }"
    ~ "message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }";

@safe unittest // the worked example from the specification
{
    auto c = make(spec);
    assert(toHex(c.encode("Outer", `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`))
            == "08011201781a02010222020809");
    assert(c.decode("Outer", hex("08011201781a02010222020809"))
            == `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`);
    assert(toHex(c.encode("Outer", "{d: {}, c: [], a: 0}")) == "2200");
    assert(c.decode("Outer", hex("3800")) == "{}");
    assertThrown!CodecException(c.decode("Outer", hex("08ff")));
}

@safe unittest // scalar types
{
    auto c = make("message M { int32 a = 1; int64 b = 2; uint32 c = 3; uint64 d = 4;"
            ~ " sint32 e = 5; sint64 f = 6; bool g = 7; fixed32 h = 8; fixed64 i = 9;"
            ~ " sfixed32 j = 10; sfixed64 k = 11; string l = 12; bytes m = 13; }");
    const text = `{a: -1, b: -9223372036854775808, c: 4294967295, d: 18446744073709551615,`
        ~ ` e: -2147483648, f: 9223372036854775807, g: true, h: 4294967295, i: 1,`
        ~ ` j: -1, k: -2, l: "\x01é\n", m: x"00ff"}`;
    const wire = c.encode("M", text);
    assert(c.decode("M", wire) == text);
    // int32 -1 is a ten-byte varint
    assert(toHex(c.encode("M", "{a: -1}")) == "08ffffffffffffffffff01");
}

@safe unittest // defaults are omitted, repeated defaults are not
{
    auto c = make("message M { int32 a = 1; string s = 2; bytes y = 3; bool b = 4; repeated int32 r = 5; }");
    assert(c.encode("M", `{a: 0, s: "", y: x"", b: false, r: []}`).length == 0);
    assert(toHex(c.encode("M", "{r: [0, 0]}")) == "2a020000");
    assert(c.decode("M", hex("2a020000")) == "{r: [0, 0]}");
}

@safe unittest // packed, unpacked and mixed repeated decoding
{
    auto c = make("message M { repeated int32 r = 1; repeated fixed32 f = 2; }");
    assert(c.decode("M", hex("0a0201020803")) == "{r: [1, 2, 3]}");
    assert(c.decode("M", hex("0a00")) == "{}");
    assert(c.decode("M", hex("120801000000ffffffff")) == "{f: [1, 4294967295]}");
    assert(c.decode("M", hex("1501000000")) == "{f: [1]}");
    assertThrown!CodecException(c.decode("M", hex("12050100000000")));
    assertThrown!CodecException(c.decode("M", hex("0a0180")));
}

@safe unittest // unknown fields, wrong wire types and groups are skipped
{
    auto c = make("message M { int32 a = 1; }");
    assert(c.decode("M", hex("1801" ~ "2a03616263" ~ "310102030405060708" ~ "3d01020304" ~ "0805")) == "{a: 5}");
    assert(c.decode("M", hex("0a03616263")) == "{}"); // wrong wire type
    assert(c.decode("M", hex("1b08011c")) == "{}");    // group
    assert(c.decode("M", hex("1b1b08011c1c0807")) == "{a: 7}"); // nested group
    assertThrown!CodecException(c.decode("M", hex("1b08011400")));  // mismatched end
    assertThrown!CodecException(c.decode("M", hex("1c")));          // stray end group
    assertThrown!CodecException(c.decode("M", hex("1b0801")));      // unterminated
    assertThrown!CodecException(c.decode("M", hex("00")));          // field 0
    assertThrown!CodecException(c.decode("M", hex("0e")));          // wire type 6
    assertThrown!CodecException(c.decode("M", hex("3d010203")));    // truncated fixed32
}

@safe unittest // merging of singular sub-messages
{
    auto c = make("message P { repeated int32 r = 1; P p = 2; string s = 3; }");
    assert(c.decode("P", hex("0801080212020803120208041a0322095c"))
            == `{r: [1, 2], p: {r: [3, 4]}, s: "\"\t\\"}`);
}

@safe unittest // string validation
{
    auto c = make("message M { string s = 1; bytes b = 2; }");
    assertThrown!CodecException(c.decode("M", hex("0a01ff")));
    assertThrown!CodecException(c.decode("M", hex("0a02c080")));
    assertThrown!CodecException(c.decode("M", hex("0a03eda080")));
    assert(c.decode("M", hex("1201ff")) == `{b: x"ff"}`);
    assertThrown!CodecException(c.encode("M", `{s: "\xc3"}`));
    assert(c.encode("M", `{s: "\xc3\xa9"}`) == c.encode("M", `{s: "é"}`));
}

@safe unittest // text parser accepts and rejects
{
    auto c = make("message M { int32 a = 1; repeated int32 c = 2; string s = 3; bool b = 4; M m = 5; }");
    assert(c.encode("M", "{a:1,c:[1,2]}") == c.encode("M", "  {  a : 1 , c : [ 1 , 2 ] }  "));
    foreach (bad; ["", " ", "{", "{a: 1}x", "{a: 01}", "{a: -0}", "{a: +5}", "{a: 1.0}",
            "{a: 2147483648}", "{a: - 1}", "{a: 1, a: 2}", "{z: 1}", "{a: [1]}", "{c: 1}",
            "{c: [1,]}", "{c: [,1]}", "{c: [1 2]}", "{a: 1,}", "{a 1}", "{s: 1}", "{a: \"1\"}",
            "{b: 1}", "{b: True}", "{b: tr ue}", "{m: 1}", "{a: {}}", "{s: \"\\q\"}", "{s: \"a\tb\"}",
            "{a:\t1}", "{s: \"abc}"])
        assertThrown!CodecException(c.encode("M", bad), bad);
    assert(c.encode("M", "{s: \"a\x7fb\"}").length == 5);
}

@safe unittest // low level API leaves the buffer unchanged on failure
{
    auto c = make("message M { int32 a = 1; }");
    ByteBuffer b;
    b.putString("keep");
    assert(!() @trusted { return c.decodeToText(0, [0x08], b); }());
    assert(c.lastError.length > 0);
    assert(!() @trusted { return c.encodeFromText(0, cast(const(ubyte)[]) "{a: x}", b); }());
    assert(b.length == 4);
    assert(() @trusted { return c.decodeToText(0, [0x08, 0x01], b); }());
    assert(cast(const(char)[]) b.data[4 .. $] == "{a: 1}");
}

@safe unittest // unknown message name
{
    auto c = make("message M { }");
    assertThrown!CodecException(c.decode("Nope", []));
    assertThrown!CodecException(c.encode("Nope", "{}"));
}
