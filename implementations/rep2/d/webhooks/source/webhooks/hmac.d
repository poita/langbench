/**
 * HMAC-SHA-256 (RFC 2104) with a precomputed key object.
 */
module webhooks.hmac;

import webhooks.sha256;

/**
 * An HMAC-SHA-256 key.
 *
 * Construction absorbs `key ^ ipad` and `key ^ opad` into two hasher states;
 * every MAC then copies those states, so the pads are never recomputed.
 */
struct HmacKey
{
    private Sha256 inner;
    private Sha256 outer;

    /// Builds the key object from raw key bytes (any length, including zero).
    this(scope const(ubyte)[] key) @safe pure nothrow @nogc
    {
        ubyte[Sha256.blockSize] padded = 0;
        if (key.length > Sha256.blockSize)
            padded[0 .. Sha256.digestSize] = sha256Of(key);
        else
            padded[0 .. key.length] = key[];

        ubyte[Sha256.blockSize] pad = void;
        foreach (i; 0 .. Sha256.blockSize)
            pad[i] = padded[i] ^ 0x36;
        inner.put(pad[]);
        foreach (i; 0 .. Sha256.blockSize)
            pad[i] = padded[i] ^ 0x5c;
        outer.put(pad[]);
    }

    /// MAC of the concatenation of `parts`, streamed without joining them.
    ubyte[32] mac(scope const(ubyte)[][] parts...) const @safe pure nothrow @nogc
    {
        Sha256 h = inner;
        foreach (p; parts)
            h.put(p);
        immutable innerDigest = h.finish();
        Sha256 o = outer;
        o.put(innerDigest[]);
        return o.finish();
    }
}

/// One-shot HMAC-SHA-256 of `message` under `key`.
ubyte[32] hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] message) @safe pure nothrow @nogc
{
    return HmacKey(key).mac(message);
}
