/// SHA-1 (FIPS 180-4), implemented from scratch.
module gitrepo.sha1;

import gitrepo.oid : ObjectId;

/// Incremental SHA-1 hasher.
struct Sha1
{
    private uint[5] h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    private ubyte[64] buf;
    private size_t bufLen;
    private ulong total;
    private uint[80] w;

    /// Feed more bytes.
    void put(scope const(ubyte)[] data) @safe pure nothrow @nogc
    {
        total += data.length;
        if (bufLen != 0)
        {
            immutable take = data.length < 64 - bufLen ? data.length : 64 - bufLen;
            buf[bufLen .. bufLen + take] = data[0 .. take];
            bufLen += take;
            data = data[take .. $];
            if (bufLen < 64)
                return;
            block(buf[]);
            bufLen = 0;
        }
        while (data.length >= 64)
        {
            block(data[0 .. 64]);
            data = data[64 .. $];
        }
        buf[0 .. data.length] = data[];
        bufLen = data.length;
    }

    /// ditto
    void put(scope const(char)[] s) @trusted pure nothrow @nogc
    {
        put(cast(const(ubyte)[]) s);
    }

    /// Finish and return the 20-byte digest. The hasher must not be reused afterwards.
    ubyte[20] finish() @safe pure nothrow @nogc
    {
        immutable ulong bits = total * 8;
        buf[bufLen++] = 0x80;
        if (bufLen > 56)
        {
            buf[bufLen .. 64] = 0;
            block(buf[]);
            bufLen = 0;
        }
        buf[bufLen .. 56] = 0;
        foreach (i; 0 .. 8)
            buf[56 + i] = cast(ubyte)(bits >> (56 - 8 * i));
        block(buf[]);
        ubyte[20] digest;
        foreach (i; 0 .. 5)
            foreach (j; 0 .. 4)
                digest[4 * i + j] = cast(ubyte)(h[i] >> (24 - 8 * j));
        return digest;
    }

    private static uint rol(uint x, uint n) @safe pure nothrow @nogc
    {
        return (x << n) | (x >> (32 - n));
    }

    private void block(scope const(ubyte)[] p) @safe pure nothrow @nogc
    {
        foreach (t; 0 .. 16)
            w[t] = (cast(uint) p[4 * t] << 24) | (cast(uint) p[4 * t + 1] << 16)
                | (cast(uint) p[4 * t + 2] << 8) | p[4 * t + 3];
        foreach (t; 16 .. 80)
            w[t] = rol(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1);
        uint a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
        foreach (t; 0 .. 20)
        {
            immutable tmp = rol(a, 5) + ((b & c) | (~b & d)) + e + 0x5A827999 + w[t];
            e = d; d = c; c = rol(b, 30); b = a; a = tmp;
        }
        foreach (t; 20 .. 40)
        {
            immutable tmp = rol(a, 5) + (b ^ c ^ d) + e + 0x6ED9EBA1 + w[t];
            e = d; d = c; c = rol(b, 30); b = a; a = tmp;
        }
        foreach (t; 40 .. 60)
        {
            immutable tmp = rol(a, 5) + ((b & c) | (b & d) | (c & d)) + e + 0x8F1BBCDC + w[t];
            e = d; d = c; c = rol(b, 30); b = a; a = tmp;
        }
        foreach (t; 60 .. 80)
        {
            immutable tmp = rol(a, 5) + (b ^ c ^ d) + e + 0xCA62C1D6 + w[t];
            e = d; d = c; c = rol(b, 30); b = a; a = tmp;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
    }
}

/// SHA-1 of a single buffer.
ubyte[20] sha1Of(scope const(ubyte)[] data) @safe pure nothrow @nogc
{
    Sha1 s;
    s.put(data);
    return s.finish();
}
