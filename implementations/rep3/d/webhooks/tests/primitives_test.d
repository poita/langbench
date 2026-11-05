/// Unit tests for SHA-256, HMAC, Base64 and hex.
module tests.primitives_test;

import webhooks;

private string hexOf(const(ubyte)[] b)
{
    return toHex(b);
}

private const(ubyte)[] bytes(string s)
{
    return asBytes(s);
}

// --- SHA-256 ---------------------------------------------------------------

unittest
{
    assert(hexOf(sha256(bytes(""))[]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert(hexOf(sha256(bytes("abc"))[]) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    assert(hexOf(sha256(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))[])
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
}

unittest
{
    // One million 'a's, fed in uneven pieces, exercises buffering across blocks.
    auto chunk = new ubyte[1000];
    chunk[] = 'a';
    Sha256 s;
    foreach (i; 0 .. 1000)
        s.update(chunk);
    assert(hexOf(s.finish()[]) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

unittest
{
    // Incremental updates equal the one-shot digest for every split point around block boundaries.
    foreach (len; [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 128, 200])
    {
        auto data = new ubyte[len];
        foreach (i, ref b; data)
            b = cast(ubyte)(i * 7 + 3);
        immutable expected = sha256(data);
        foreach (split; 0 .. len + 1)
        {
            Sha256 s;
            s.update(data[0 .. split]);
            s.update(data[split .. $]);
            assert(s.finish() == expected);
        }
    }
}

unittest
{
    // A hasher is a value: copying it snapshots the state.
    Sha256 a;
    a.update(bytes("ab"));
    Sha256 b = a;
    a.update(bytes("c"));
    assert(hexOf(a.finish()[]) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    b.update(bytes("d"));
    assert(b.finish() == sha256(bytes("abd")));
}

// --- HMAC ------------------------------------------------------------------

unittest
{
    // RFC 4231 test case 1
    auto key = new ubyte[20];
    key[] = 0x0b;
    assert(hexOf(hmacSha256(key, bytes("Hi There"))[])
            == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    // test case 2
    assert(hexOf(hmacSha256(bytes("Jefe"), bytes("what do ya want for nothing?"))[])
            == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
}

unittest
{
    // RFC 4231 test case 6: key longer than the block size.
    auto key = new ubyte[131];
    key[] = 0xaa;
    assert(hexOf(hmacSha256(key, bytes("Test Using Larger Than Block-Size Key - Hash Key First"))[])
            == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
}

unittest
{
    // Empty key and empty message are legal.
    assert(hexOf(hmacSha256(null, null)[])
            == "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad");
}

unittest
{
    // Streaming parts equals MAC of the concatenation; a key can be reused.
    auto key = HmacKey(bytes("secret"));
    assert(key.mac(bytes("foo"), bytes("."), bytes("bar")) == hmacSha256(bytes("secret"), bytes("foo.bar")));
    assert(key.mac(bytes("x")) == hmacSha256(bytes("secret"), bytes("x")));
}

// --- Base64 ----------------------------------------------------------------

unittest
{
    assert(encodeStandard(bytes("")) == "");
    assert(encodeStandard(bytes("f")) == "Zg==");
    assert(encodeStandard(bytes("fo")) == "Zm8=");
    assert(encodeStandard(bytes("foo")) == "Zm9v");
    assert(encodeStandard(bytes("foobar")) == "Zm9vYmFy");
    immutable ubyte[] fbff = [0xfb, 0xff];
    assert(encodeStandard(fbff) == "+/8=");
    assert(encodeUrlSafe(fbff) == "-_8");
    assert(encodeUrlSafe(bytes("f")) == "Zg");
}

unittest
{
    ubyte[] r;
    assert(decode(bytes(""), r) && r.length == 0);
    assert(decode(bytes("Zm9vYg=="), r) && r == bytes("foob"));
    assert(decode(bytes("Zm9vYg"), r) && r == bytes("foob")); // padding optional
    assert(decode(bytes("+/8="), r) && r == [0xfb, 0xff]);
    assert(decode(bytes("-_8"), r) && r == [0xfb, 0xff]); // URL-safe accepted
    // trailing bits are not checked
    ubyte[] r1, r2;
    assert(decode(bytes("QQ=="), r1) && decode(bytes("QR=="), r2) && r1 == r2 && r1 == [0x41]);
}

unittest
{
    ubyte[] r;
    foreach (bad; ["A", "AAAAA", "=", "====", "AA=", "AAA==", "AAAA=", "AA===", "A=AA",
            "AA A", "AA\n", "A*AA", "+-AA", "AA+-", "_/AA", "Zm9v=", "Zg=a", "Zm9vYg=== "])
        assert(!decode(bytes(bad), r), bad);
}

unittest
{
    // Round trip for all lengths and byte values.
    ubyte[] data;
    foreach (n; 0 .. 70)
    {
        data ~= cast(ubyte)(n * 37);
        ubyte[] back;
        assert(decode(bytes(encodeStandard(data)), back) && back == data);
        assert(decode(bytes(encodeUrlSafe(data)), back) && back == data);
    }
}

// --- hex -------------------------------------------------------------------

unittest
{
    ubyte[] r;
    assert(decodeHex(bytes("-"), r) && r.length == 0);
    assert(decodeHex(bytes("00ff7a"), r) && r == [0x00, 0xff, 0x7a]);
    foreach (bad; ["", "abc", "AB", "0g", " 0", "--", "-0", "0x"])
        assert(!decodeHex(bytes(bad), r), bad);
    assert(toHex([0xde, 0xad]) == "dead");
}

unittest
{
    OutBuffer o;
    putHexOrDash(o, null);
    o.put(" ");
    putHexOrDash(o, bytes("a"));
    assert(o.toString() == "- 61");
}
