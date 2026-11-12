/// High-level conversions between bytes, hex and canonical text.
module protowire.codec;

import std.array : Appender;
import protowire.decoder : decodeMessage;
import protowire.encoder : encodeMessage;
import protowire.hex;
import protowire.schema : MessageDescriptor, Schema;
import protowire.textformat : CharBuffer, formatMessage, formatMessageTo, parseMessage;

/// Decodes wire-format `bytes` as message `desc` and renders canonical text.
/// Throws `WireException` on malformed data.
string decodeToText(const MessageDescriptor desc, const(ubyte)[] bytes) @safe
{
    return formatMessage(decodeMessage(desc, bytes));
}

/// Parses text form as message `desc` and returns its canonical wire encoding.
/// Throws `TextException` if the text is not valid for `desc`.
ubyte[] encodeFromText(const MessageDescriptor desc, scope const(char)[] text) @safe
{
    return encodeMessage(parseMessage(desc, text));
}

/// `decodeToText` for a hex string (lowercase digits, may be empty).
string decodeHexToText(const MessageDescriptor desc, scope const(char)[] hex) @safe
{
    return decodeToText(desc, fromHex(hex));
}

/// `encodeFromText`, returning lowercase hex (empty for an empty encoding).
string encodeTextToHex(const MessageDescriptor desc, scope const(char)[] text) @safe
{
    return toHex(encodeFromText(desc, text));
}

@safe unittest
{
    auto schema = Schema.parse(`
        message Inner { sint32 v = 1; }
        message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }`);
    auto outer = schema["Outer"];

    assert(encodeTextToHex(outer, `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`) == "08011201781a02010222020809");
    assert(decodeHexToText(outer, "08011201781a02010222020809") == `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`);
    assert(encodeTextToHex(outer, `{d: {}, c: [], a: 0}`) == "2200");
    assert(encodeTextToHex(outer, `{}`) == "");
    assert(decodeHexToText(outer, "3800") == `{}`);
}

// Property test: canonical text survives encode -> decode unchanged.
unittest
{
    import std.conv : to;
    import std.random : Random, uniform;

    auto schema = Schema.parse(`
        message T { int32 i32 = 1; int64 i64 = 2; uint32 u32 = 3; uint64 u64 = 4; sint32 s32 = 5;
            sint64 s64 = 6; bool b = 7; fixed32 f32 = 8; fixed64 f64 = 9; sfixed32 sf32 = 10;
            sfixed64 sf64 = 11; string s = 12; bytes y = 13; repeated sint64 rs = 14;
            repeated fixed32 rf = 15; repeated bool rb = 16; repeated string rstr = 17;
            repeated T kids = 18; T one = 19; }`);
    auto rng = Random(12345);

    string value(ref Random r, int depth)
    {
        string[] parts;
        long nz() { auto v = uniform(-1000L, 1000L, r); return v == 0 ? 1 : v; }
        if (uniform(0, 2, r)) parts ~= "i32: " ~ (nz()).to!string;
        if (uniform(0, 2, r)) parts ~= "i64: " ~ (-nz() * 1_000_000_000_000L).to!string;
        if (uniform(0, 2, r)) parts ~= "u32: " ~ (nz() < 0 ? 4_000_000_000 : 7).to!string;
        if (uniform(0, 2, r)) parts ~= "u64: 18446744073709551615";
        if (uniform(0, 2, r)) parts ~= "s32: " ~ nz().to!string;
        if (uniform(0, 2, r)) parts ~= "s64: -9223372036854775808";
        if (uniform(0, 2, r)) parts ~= "b: true";
        if (uniform(0, 2, r)) parts ~= "f32: " ~ (nz() ^^ 2 * 4000).to!string;
        if (uniform(0, 2, r)) parts ~= "sf32: -2147483648";
        if (uniform(0, 2, r)) parts ~= "sf64: " ~ nz().to!string;
        if (uniform(0, 2, r)) parts ~= `s: "a\"é\n\x00z"`;
        if (uniform(0, 2, r)) parts ~= `y: x"00ff10"`;
        if (uniform(0, 2, r)) parts ~= "rs: [" ~ nz().to!string ~ ", 0, -1]";
        if (uniform(0, 2, r)) parts ~= "rf: [0, 4294967295]";
        if (uniform(0, 2, r)) parts ~= "rb: [false, true]";
        if (uniform(0, 2, r)) parts ~= `rstr: ["", "x y"]`;
        if (depth < 4 && uniform(0, 2, r))
            parts ~= "kids: [" ~ value(r, depth + 1) ~ ", {}]";
        if (depth < 4 && uniform(0, 2, r)) parts ~= "one: " ~ value(r, depth + 1);
        string s = "{";
        foreach (i, p; parts)
            s ~= (i ? ", " : "") ~ p;
        return s ~ "}";
    }

    foreach (n; 0 .. 200)
    {
        auto text = value(rng, 0);
        auto hex = encodeTextToHex(schema["T"], text);
        // re-encoding the decoded text must reproduce the same bytes
        auto back = decodeHexToText(schema["T"], hex);
        assert(encodeTextToHex(schema["T"], back) == hex, text);
        assert(decodeHexToText(schema["T"], hex) == back);
    }
}
