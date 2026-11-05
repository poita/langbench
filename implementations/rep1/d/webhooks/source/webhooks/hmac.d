/**
 * HMAC-SHA-256 (RFC 2104) with precomputed key states.
 *
 * An `HmacKey` stores the SHA-256 states after absorbing `key ^ ipad` and
 * `key ^ opad`. Computing a MAC copies those states and streams the message
 * parts through them, so the message is never concatenated or copied.
 */
module webhooks.hmac;

import webhooks.sha256;

/// An in-progress MAC computation obtained from `HmacKey.start`.
struct HmacStream
{
    private Sha256 inner;
    private Sha256 outer;

    /// Streams more message bytes.
    void put(scope const(ubyte)[] data) @safe pure nothrow @nogc
    {
        inner.put(data);
    }

    /// Finishes and returns the 32-byte MAC.
    ubyte[32] finish() @safe pure nothrow @nogc
    {
        immutable innerDigest = inner.finish();
        outer.put(innerDigest[]);
        return outer.finish();
    }
}

/// A key prepared for repeated HMAC-SHA-256 computations.
struct HmacKey
{
    private Sha256 inner;
    private Sha256 outer;

    /// Prepares `key` (any length, including empty).
    this(scope const(ubyte)[] key) @safe pure nothrow @nogc
    {
        ubyte[64] padded = 0;
        if (key.length > 64)
            padded[0 .. 32] = sha256Of(key);
        else
            padded[0 .. key.length] = key[];
        ubyte[64] ipad = void, opad = void;
        foreach (i; 0 .. 64)
        {
            ipad[i] = padded[i] ^ 0x36;
            opad[i] = padded[i] ^ 0x5c;
        }
        inner.put(ipad[]);
        outer.put(opad[]);
    }

    /// Begins a MAC computation.
    HmacStream start() const @safe pure nothrow @nogc
    {
        HmacStream s;
        s.inner = inner;
        s.outer = outer;
        return s;
    }

    /// MAC of the concatenation of `parts`, computed without concatenating.
    ubyte[32] mac(scope const(const(ubyte)[])[] parts...) const @safe pure nothrow @nogc
    {
        auto s = start();
        foreach (p; parts)
            s.put(p);
        return s.finish();
    }
}

/// One-shot HMAC-SHA-256.
ubyte[32] hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] message) @safe pure nothrow @nogc
{
    return HmacKey(key).mac(message);
}
