module parser_tests;

import canonjson;
import helpers;

private bool valid(const(char)[] s) { return canon(s) != "invalid"; }

unittest // scalars at top level
{
    assert(canon("null") == "null");
    assert(canon(" true ") == "true");
    assert(canon("false") == "false");
    assert(canon("\"x\"") == "\"x\"");
    assert(canon("0") == "0");
    assert(canon("\t\r\n [ ] \n") == "[]");
    assert(canon("{ }") == "{}");
}

unittest // value tree
{
    auto v = parse(`{"a":[1,"x",null,true],"b":{}}`);
    assert(v.kind == Kind.object);
    assert(v.object.length == 2);
    assert(v.object[0].key == cast(const(ubyte)[]) "a");
    auto arr = v.object[0].value.array;
    assert(arr.length == 4);
    assert(arr[0].kind == Kind.number && arr[0].numberText == cast(const(ubyte)[]) "1");
    assert(arr[1].kind == Kind.string && arr[1].str == "x");
    assert(arr[2].kind == Kind.null_);
    assert(arr[3].kind == Kind.true_);
    assert(v.object[1].value.kind == Kind.object);
}

unittest // duplicates are preserved in the tree, in input order
{
    auto v = parse(`{"a":1,"a":2}`);
    assert(v.object.length == 2);
}

unittest // exceptions carry an offset
{
    try
    {
        parse(`[1,]`);
        assert(0);
    }
    catch (ParseException e)
    {
        assert(e.offset == 3);
    }
}

unittest // whitespace
{
    assert(!valid("\x0c1"));
    assert(!valid("\x0b1"));
    assert(!valid("1\x00"));
    assert(!valid(""));
    assert(!valid(" \n\t\r"));
    assert(!valid("\u00a0" ~ "1"));
    assert(!valid("\u2028" ~ "1"));
    assert(!valid("\u0085" ~ "1"));
    assert(valid("\t\n\r 1\t\n\r "));
}

unittest // literals
{
    foreach (s; ["True", "NULL", "nul", "NaN", "Infinity", "-Infinity", "truee", "tru", "fals", "nullx"])
        assert(!valid(s), s);
}

unittest // structure errors
{
    foreach (s; ["[1,]", "[,1]", "[1,,2]", "[1 2]", "[", "]", "{", "{\"a\"}", "{\"a\":}", "{\"a\":1,}",
                 "{,}", "{1:2}", "{a:1}", "{'a':1}", "{\"a\" 1}", "[1]]", "[1] 2", "1 2", "//x\n1",
                 "/* */1", "{\"a\":1 \"b\":2}", "[\"a\" \"b\"]", "{\"a\":1:2}"])
        assert(!valid(s), s);
}

unittest // numbers: valid and invalid lexemes
{
    foreach (s; ["0", "-0", "1", "-1", "10", "0.5", "-0.0", "1e5", "1E5", "1e+5", "1e-5", "0e0", "1.5e10"])
        assert(valid(s), s);
    foreach (s; ["01", "-01", "+1", "-", "1.", ".5", "1e", "1e+", "1E+-5", "1e5e5", "0x1", "- 1", "1 .5",
                 "1.e5", "--1", "1.5.5", "\u0662", "\u00b2", "\uff11", "1\u0662", "1.\u0662", "1e\u0662",
                 "Infinity", "-NaN"])
        assert(!valid(s), s);
}

unittest // strings
{
    assert(valid(`"\"\\\/\b\f\n\r\t"`));
    assert(valid(`"\u0041\u00e9\uD83D\uDE00"`));
    assert(valid("\"\u007f\u2028\""));
    foreach (s; [`"`, `"abc`, `"\`, `"\x"`, `"\U0041"`, `"\'"`, `"\0"`, `"\u12"`, `"\u12G4"`, `"\u+123"`,
                 "\"\t\"", "\"\n\"", "\"\x00\"", "\"\x1f\"", `'a'`, "\"\"\"",
                 "\"\\u\uff11\uff11\uff11\uff11\""])
        assert(!valid(s), s);
}

unittest // surrogates
{
    assert(valid(`"\uD800\uDC00"`));
    assert(valid(`"\uDBFF\uDFFF"`));
    assert(valid(`"\ud83d\ude00"`));
    foreach (s; [`"\uD800"`, `"\uD800\u0041"`, `"\uD800\uE000"`, `"\uD800\uDBFF"`, `"\uD800x"`,
                 `"\uDC00"`, `"\uDC00\uD800"`, `"\uD800\n"`, `{"\uD800":1}`, `"\uD800\`])
        assert(!valid(s), s);
}

unittest // validity is a property of the whole document
{
    assert(!valid(`{"a":"\uD800","a":1}`));
    assert(!valid(`{"a":[1,],"a":1}`));
    assert(!valid(`{"a":1,"a":01}`));
}

unittest // UTF-8 and BOM
{
    assert(canonBytes([0xEF, 0xBB, 0xBF, '1']) == "invalid");
    assert(canonBytes(['"', 0xC3, 0xA9, '"']) == "\"\u00e9\"");
    assert(canonBytes(['"', 0xC3, '"']) == "invalid");
    assert(canonBytes(['"', 0xC0, 0x80, '"']) == "invalid");
    assert(canonBytes(['"', 0xED, 0xA0, 0x80, '"']) == "invalid");
    assert(canonBytes(['"', 0xF4, 0x90, 0x80, 0x80, '"']) == "invalid");
    assert(canonBytes([0xFF]) == "invalid");
    assert(canonBytes(['1', ' ', 0x80]) == "invalid");
}

unittest // nesting depth
{
    import std.array : replicate;
    assert(valid("[".replicate(512) ~ "]".replicate(512)));
    assert(!valid("[".replicate(513) ~ "]".replicate(513)));
    assert(valid(`{"a":`.replicate(512) ~ "1" ~ "}".replicate(512)));
    assert(!valid(`{"a":`.replicate(513) ~ "1" ~ "}".replicate(513)));
    assert(valid("[".replicate(511) ~ "{}" ~ "]".replicate(511)));
    assert(!valid("[".replicate(512) ~ "{}" ~ "]".replicate(512)));
    assert(!valid("[".replicate(100_000)));
    // siblings do not accumulate depth
    assert(valid("[" ~ "[],".replicate(1000) ~ "[]]"));
}
