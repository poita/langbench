/**
 * HMAC-SHA-256 (RFC 2104 with a 64-byte block), built on `webhooks.sha256`.
 */
module webhooks.hmac;

import webhooks.sha256;

/**
 * Incremental HMAC-SHA-256.
 *
 * Constructing an `Hmac` absorbs the key into the inner and outer hash states
 * once; the struct is a value type, so a keyed `Hmac` can be copied for every
 * message that has to be authenticated with the same key.
 */
struct Hmac
{
    private Sha256 inner;
    private Sha256 outer;

    /// Keys the MAC. Keys longer than 64 bytes are hashed first; an empty key
    /// is legal.
    this(scope const(ubyte)[] key) pure nothrow @safe @nogc
    {
        ubyte[sha256BlockSize] block = 0;
        if (key.length > sha256BlockSize)
            block[0 .. sha256DigestSize] = sha256(key);
        else
            block[0 .. key.length] = key[];

        ubyte[sha256BlockSize] pad = void;
        foreach (i; 0 .. sha256BlockSize)
            pad[i] = block[i] ^ 0x36;
        inner.put(pad[]);
        foreach (i; 0 .. sha256BlockSize)
            pad[i] = block[i] ^ 0x5c;
        outer.put(pad[]);
    }

    /// Appends `data` to the message.
    void put(scope const(ubyte)[] data) pure nothrow @safe @nogc
    {
        inner.put(data);
    }

    /// ditto
    void put(scope const(char)[] text) pure nothrow @safe @nogc
    {
        inner.put(text);
    }

    /// Returns the 32-byte tag. The object must not be used afterwards.
    ubyte[32] finish() pure nothrow @safe @nogc
    {
        immutable innerDigest = inner.finish();
        outer.put(innerDigest[]);
        return outer.finish();
    }
}

/// One-shot HMAC-SHA-256 of `message` under `key`.
ubyte[32] hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] message) pure nothrow @safe @nogc
{
    auto mac = Hmac(key);
    mac.put(message);
    return mac.finish();
}

/// RFC 4231 test case 1.
@safe unittest
{
    import webhooks.hex : toHex;

    ubyte[20] key = 0x0b;
    assert(toHex(hmacSha256(key[], cast(const(ubyte)[]) "Hi There"))
            == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
}

/// RFC 4231 test cases 2 and 6 (key longer than the block size).
@safe unittest
{
    import webhooks.hex : toHex;

    assert(toHex(hmacSha256(cast(const(ubyte)[]) "Jefe", cast(const(ubyte)[]) "what do ya want for nothing?"))
            == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");

    ubyte[131] key = 0xaa;
    assert(toHex(hmacSha256(key[], cast(const(ubyte)[]) "Test Using Larger Than Block-Size Key - Hash Key First"))
            == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
}

@safe unittest
{
    import webhooks.hex : toHex;

    assert(toHex(hmacSha256([], [])) == "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad");

    // A keyed Hmac can be copied and reused.
    immutable keyed = Hmac(cast(const(ubyte)[]) "k");
    Hmac a = keyed;
    Hmac b = keyed;
    a.put("ab");
    a.put("cd");
    b.put("abcd");
    assert(a.finish() == b.finish());
}
