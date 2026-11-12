/// SHA-1 (FIPS 180-4), implemented from scratch.
module gitrepo.sha1;

/// Incremental SHA-1 hasher.
struct Sha1
{
    private uint[5] h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    private ubyte[64] buf;
    private size_t bufLen;
    private ulong total;

    /// Feed more bytes into the hash.
    void put(scope const(ubyte)[] data) @safe pure nothrow @nogc
    {
        total += data.length;
        if (bufLen > 0)
        {
            immutable n = data.length < 64 - bufLen ? data.length : 64 - bufLen;
            buf[bufLen .. bufLen + n] = data[0 .. n];
            bufLen += n;
            data = data[n .. $];
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
    void put(scope const(char)[] text) @trusted pure nothrow @nogc
    {
        put(cast(const(ubyte)[]) text);
    }

    /// Finish and return the 20-byte digest. The hasher must not be reused.
    ubyte[20] finish() @safe pure nothrow @nogc
    {
        immutable ulong bits = total * 8;
        ubyte[72] pad;
        pad[0] = 0x80;
        immutable padLen = (bufLen < 56) ? 56 - bufLen : 120 - bufLen;
        foreach (i; 0 .. 8)
            pad[padLen + i] = cast(ubyte)(bits >> (56 - 8 * i));
        put(pad[0 .. padLen + 8]);
        assert(bufLen == 0);
        ubyte[20] digest;
        foreach (i; 0 .. 5)
            foreach (j; 0 .. 4)
                digest[i * 4 + j] = cast(ubyte)(h[i] >> (24 - 8 * j));
        return digest;
    }

    private void block(scope const(ubyte)[] p) @safe pure nothrow @nogc
    {
        uint[80] w = void;
        foreach (i; 0 .. 16)
            w[i] = (cast(uint) p[4 * i] << 24) | (cast(uint) p[4 * i + 1] << 16)
                | (cast(uint) p[4 * i + 2] << 8) | p[4 * i + 3];
        foreach (i; 16 .. 80)
        {
            immutable x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
            w[i] = (x << 1) | (x >> 31);
        }
        uint a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
        foreach (i; 0 .. 80)
        {
            uint f, k;
            if (i < 20)
            {
                f = (b & c) | (~b & d);
                k = 0x5A827999;
            }
            else if (i < 40)
            {
                f = b ^ c ^ d;
                k = 0x6ED9EBA1;
            }
            else if (i < 60)
            {
                f = (b & c) | (b & d) | (c & d);
                k = 0x8F1BBCDC;
            }
            else
            {
                f = b ^ c ^ d;
                k = 0xCA62C1D6;
            }
            immutable t = ((a << 5) | (a >> 27)) + f + e + k + w[i];
            e = d;
            d = c;
            c = (b << 30) | (b >> 2);
            b = a;
            a = t;
        }
        h[0] += a;
        h[1] += b;
        h[2] += c;
        h[3] += d;
        h[4] += e;
    }
}

/// One-shot SHA-1 of `data`.
ubyte[20] sha1Of(scope const(ubyte)[] data) @safe pure nothrow @nogc
{
    Sha1 s;
    s.put(data);
    return s.finish();
}

unittest
{
    import gitrepo.hex : toHex;

    assert(toHex(sha1Of([])) == "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    assert(toHex(sha1Of(cast(const(ubyte)[]) "abc")) == "a9993e364706816aba3e25717850c26c9cd0d89d");
    assert(toHex(sha1Of(cast(const(ubyte)[]) "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
            == "84983e441c3bd26ebaae4aa1f95129e5e54670f1");
    // The id of a blob holding "one file\n" (SPEC.md).
    assert(toHex(sha1Of(cast(const(ubyte)[]) "blob 9\0one file\n"))
            == "b7814cae2e925fe74c6cd5816462fff515ccb256");
}

unittest
{
    import gitrepo.hex : toHex;

    // One million 'a', fed in awkward chunk sizes.
    Sha1 s;
    auto chunk = new ubyte[](997);
    chunk[] = 'a';
    size_t left = 1_000_000;
    while (left)
    {
        immutable n = left < chunk.length ? left : chunk.length;
        s.put(chunk[0 .. n]);
        left -= n;
    }
    assert(toHex(s.finish()) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f");
}
