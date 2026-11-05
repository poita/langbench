/**
 * HMAC-SHA-256 (RFC 2104) with precomputed key pads.
 */
module webhooks.hmac;

import webhooks.buffer : Bytes;
import webhooks.sha256;

/**
 * A key prepared for HMAC-SHA-256.
 *
 * Construction hashes the key (if longer than a block) and absorbs
 * `key ^ ipad` and `key ^ opad` into two hashers once; every MAC then just
 * copies those two states.
 */
struct HmacKey
{
    private Sha256 inner;
    private Sha256 outer;

    /// Prepare `key` (any length, including zero) for MACs.
    this(Bytes key) @safe pure nothrow @nogc
    {
        ubyte[sha256BlockLength] padded = 0;
        if (key.length > sha256BlockLength)
            padded[0 .. sha256DigestLength] = sha256(key);
        else
            padded[0 .. key.length] = key[];

        ubyte[sha256BlockLength] ipad = void, opad = void;
        foreach (i; 0 .. sha256BlockLength)
        {
            ipad[i] = padded[i] ^ 0x36;
            opad[i] = padded[i] ^ 0x5c;
        }
        inner.update(ipad[]);
        outer.update(opad[]);
    }

    /**
     * MAC of the concatenation of `parts`, streamed through the hasher without
     * building the concatenated message.
     */
    ubyte[32] mac(scope const(Bytes)[] parts...) const @safe pure nothrow @nogc
    {
        Sha256 i = inner;
        foreach (p; parts)
            i.update(p);
        immutable innerDigest = i.finish();
        Sha256 o = outer;
        o.update(innerDigest[]);
        return o.finish();
    }
}

/// One-shot HMAC-SHA-256 of `message` under `key`.
ubyte[32] hmacSha256(Bytes key, Bytes message) @safe pure nothrow @nogc
{
    return HmacKey(key).mac(message);
}
