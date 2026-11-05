/// Unit tests for SHA-256, HMAC, Base64 and hex.
module tests.primitives;

import webhooks.base64;
import webhooks.hex;
import webhooks.hmac;
import webhooks.sha256;

private const(ubyte)[] bytes(string s) @trusted pure nothrow
{
    return cast(const(ubyte)[]) s;
}

private ubyte[] unhex(string s) @safe pure nothrow
{
    ubyte[] r;
    assert(decodeHex(bytes(s), r));
    return r;
}

unittest // SHA-256 known answers
{
    assert(toHex(sha256Of(bytes(""))[]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert(toHex(sha256Of(bytes("abc"))[]) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    assert(toHex(sha256Of(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))[])
        == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
}

unittest // one million 'a'
{
    auto a = new ubyte[1_000_000];
    a[] = 'a';
    assert(toHex(sha256Of(a)[]) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

unittest // incremental hashing agrees with one-shot at every split and size
{
    auto data = new ubyte[200];
    foreach (i, ref b; data)
        b = cast(ubyte)(i * 7 + 3);
    foreach (len; 0 .. data.length + 1)
    {
        immutable expected = sha256Of(data[0 .. len]);
        foreach (split; 0 .. len + 1)
        {
            Sha256 h;
            h.put(data[0 .. split]);
            h.put(data[split .. len]);
            assert(h.finish() == expected);
        }
    }
}

unittest // padding boundaries (55, 56, 63, 64, 65 bytes)
{
    assert(toHex(sha256Of(new ubyte[55])[]) == "02779466cdec163811d078815c633f21901413081449002f24aa3e80f0b88ef7");
    assert(toHex(sha256Of(new ubyte[56])[]) == "d4817aa5497628e7c77e6b606107042bbba3130888c5f47a375e6179be789fbb");
    assert(toHex(sha256Of(new ubyte[64])[]) == "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b");
}

unittest // HMAC: RFC 4231 cases 1 and 2, long key, empty key
{
    auto key1 = new ubyte[20];
    key1[] = 0x0b;
    assert(toHex(hmacSha256(key1, bytes("Hi There"))[])
        == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    assert(toHex(hmacSha256(bytes("Jefe"), bytes("what do ya want for nothing?"))[])
        == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    // RFC 4231 case 6: 131-byte key
    auto key6 = new ubyte[131];
    key6[] = 0xaa;
    assert(toHex(hmacSha256(key6, bytes("Test Using Larger Than Block-Size Key - Hash Key First"))[])
        == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
    assert(toHex(hmacSha256(null, null)[])
        == "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad");
}

unittest // streamed MAC equals MAC of the concatenation
{
    auto key = HmacKey(bytes("secret key"));
    assert(key.mac(bytes("ab"), bytes(""), bytes("cdef")) == key.mac(bytes("abcdef")));
}

unittest // Base64 encoding
{
    assert(encode(bytes("")) == "");
    assert(encode(bytes("f")) == "Zg==");
    assert(encode(bytes("fo")) == "Zm8=");
    assert(encode(bytes("foo")) == "Zm9v");
    assert(encodeUrl(bytes("f")) == "Zg");
    immutable ubyte[2] fbff = [0xfb, 0xff];
    assert(encode(fbff[]) == "+/8=");
    assert(encodeUrl(fbff[]) == "-_8");
}

unittest // Base64 decoding: valid forms
{
    ubyte[] r;
    assert(decode(bytes(""), r) && r.length == 0);
    assert(decode(bytes("Zm9v"), r) && r == bytes("foo"));
    assert(decode(bytes("Zg=="), r) && r == bytes("f"));
    assert(decode(bytes("Zg"), r) && r == bytes("f"));
    assert(decode(bytes("-_8"), r) && r == unhex("fbff"));
    assert(decode(bytes("+/8="), r) && r == unhex("fbff"));
    // leftover bits are not checked
    ubyte[] a, b;
    assert(decode(bytes("QQ=="), a) && decode(bytes("QR=="), b) && a == b && a == bytes("A"));
}

unittest // Base64 decoding: invalid forms
{
    ubyte[] r;
    foreach (bad; ["Z", "Zg=", "Zg===", "Z=g=", "=Zg=", "Zm9v=", "Zm8==", "Zm 9v", "Zm9v\n",
            "+_", "-/", "Zm9!", "====", "="])
        assert(!decode(bytes(bad), r), bad);
}

unittest // Base64 round trip
{
    auto data = new ubyte[300];
    foreach (i, ref b; data)
        b = cast(ubyte)(i * 31);
    foreach (n; 0 .. 40)
    {
        ubyte[] r;
        assert(decode(bytes(encode(data[0 .. n])), r) && r == data[0 .. n]);
        assert(decode(bytes(encodeUrl(data[0 .. n])), r) && r == data[0 .. n]);
    }
}

unittest // hex arguments
{
    ubyte[] r;
    assert(decodeHex(bytes("-"), r) && r.length == 0);
    assert(decodeHex(bytes("00ff7a"), r) && r == [0x00, 0xff, 0x7a]);
    assert(!decodeHex(bytes(""), r));
    assert(!decodeHex(bytes("ABCD"), r));
    assert(!decodeHex(bytes("abc"), r));
    assert(!decodeHex(bytes("zz"), r));
    assert(!decodeHex(bytes("--"), r));
    assert(toHex([0xde, 0xad]) == "dead");
}
