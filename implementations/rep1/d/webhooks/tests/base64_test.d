module base64_test;

import webhooks.base64;

private ubyte[] bytes(string s) { return cast(ubyte[]) s.dup; }

@("base64: encoding table from the spec")
unittest
{
    assert(encodeStandard(bytes("")) == "");
    assert(encodeStandard(bytes("f")) == "Zg==");
    assert(encodeStandard(bytes("fo")) == "Zm8=");
    assert(encodeStandard(bytes("foo")) == "Zm9v");
    assert(encodeStandard([0xfb, 0xff]) == "+/8=");
    assert(encodeUrlSafe(bytes("f")) == "Zg");
    assert(encodeUrlSafe([0xfb, 0xff]) == "-_8");
}

@("base64: valid decodes")
unittest
{
    ubyte[] r;
    assert(decode("", r) && r.length == 0);
    assert(decode("Zm9v", r) && r == bytes("foo"));
    assert(decode("Zm8=", r) && r == bytes("fo"));
    assert(decode("Zm8", r) && r == bytes("fo"));
    assert(decode("-_8", r) && r == [0xfb, 0xff]);
    assert(decode("+/8=", r) && r == [0xfb, 0xff]);
}

@("base64: trailing bits are ignored")
unittest
{
    ubyte[] a, b;
    assert(decode("QQ==", a) && decode("QR==", b));
    assert(a == [0x41] && b == [0x41]);
}

@("base64: invalid inputs")
unittest
{
    ubyte[] r;
    foreach (bad; ["A", "AAAAA", "Zg=", "Zg===", "Zm9v=", "Zm=8", "=Zg", "Zg ==", "Zm9v\n",
        "+-", "_/", "Zm8==", "Z!==", "====", "="])
        assert(!decode(bad, r), bad);
}

@("base64: round trip of every length")
unittest
{
    ubyte[] data;
    foreach (n; 0 .. 40)
    {
        ubyte[] r;
        assert(decode(encodeStandard(data), r) && r == data);
        assert(decode(encodeUrlSafe(data), r) && r == data);
        data ~= cast(ubyte)(n * 37 + 11);
    }
}
