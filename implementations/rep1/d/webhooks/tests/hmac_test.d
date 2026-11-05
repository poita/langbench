module hmac_test;

import webhooks.hex : toHex;
import webhooks.hmac;

@("hmac: RFC 4231 test case 1")
unittest
{
    auto key = new ubyte[20];
    key[] = 0x0b;
    assert(toHex(hmacSha256(key, cast(const(ubyte)[]) "Hi There")[]) ==
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
}

@("hmac: RFC 4231 test case 2 (short key)")
unittest
{
    assert(toHex(hmacSha256(cast(const(ubyte)[]) "Jefe",
        cast(const(ubyte)[]) "what do ya want for nothing?")[]) ==
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
}

@("hmac: RFC 4231 test case 6 (key longer than block)")
unittest
{
    auto key = new ubyte[131];
    key[] = 0xaa;
    assert(toHex(hmacSha256(key, cast(const(ubyte)[]) "Test Using Larger Than Block-Size Key - Hash Key First")[]) ==
        "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
}

@("hmac: empty key and message")
unittest
{
    assert(toHex(hmacSha256([], [])[]) ==
        "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad");
}

@("hmac: streamed parts equal one concatenated message")
unittest
{
    auto key = HmacKey(cast(const(ubyte)[]) "secret");
    immutable whole = key.mac(cast(const(ubyte)[]) "id.123.body");
    immutable parts = key.mac(cast(const(ubyte)[]) "id", cast(const(ubyte)[]) ".",
        cast(const(ubyte)[]) "123", cast(const(ubyte)[]) ".", cast(const(ubyte)[]) "body");
    assert(whole == parts);
    // The key object is reusable.
    assert(key.mac(cast(const(ubyte)[]) "id.123.body") == whole);
}
