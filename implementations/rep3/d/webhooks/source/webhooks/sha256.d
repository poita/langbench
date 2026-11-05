/**
 * SHA-256 (FIPS 180-4), written from scratch.
 *
 * `Sha256` is an incremental hasher. It is a plain value type (fixed-size
 * arrays only), so copying it snapshots the state — HMAC relies on that.
 */
module webhooks.sha256;

import webhooks.buffer : Bytes;

/// Length of a SHA-256 digest in bytes.
enum size_t sha256DigestLength = 32;
/// Length of a SHA-256 input block in bytes.
enum size_t sha256BlockLength = 64;

private static immutable uint[64] roundConstants = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

private uint ror(uint x, uint n) @safe pure nothrow @nogc
{
    return (x >> n) | (x << (32 - n));
}

/// Incremental SHA-256 hasher.
struct Sha256
{
    private uint[8] h = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    private ubyte[64] block;
    private size_t blockLen;
    private ulong totalLen;

    /// Absorb more message bytes. Full blocks are compressed straight from `data`.
    void update(Bytes data) @safe pure nothrow @nogc
    {
        totalLen += data.length;
        if (blockLen > 0)
        {
            immutable room = 64 - blockLen;
            immutable take = data.length < room ? data.length : room;
            block[blockLen .. blockLen + take] = data[0 .. take];
            blockLen += take;
            data = data[take .. $];
            if (blockLen < 64)
                return;
            compress(block[]);
            blockLen = 0;
        }
        while (data.length >= 64)
        {
            compress(data[0 .. 64]);
            data = data[64 .. $];
        }
        block[0 .. data.length] = data[];
        blockLen = data.length;
    }

    /// Pad, finish and return the digest. The hasher must not be reused afterwards.
    ubyte[32] finish() @safe pure nothrow @nogc
    {
        immutable ulong bitLength = totalLen * 8;
        block[blockLen++] = 0x80;
        if (blockLen > 56)
        {
            block[blockLen .. $] = 0;
            compress(block[]);
            blockLen = 0;
        }
        block[blockLen .. 56] = 0;
        foreach (i; 0 .. 8)
            block[56 + i] = cast(ubyte)(bitLength >> (56 - 8 * i));
        compress(block[]);

        ubyte[32] digest = void;
        foreach (i; 0 .. 8)
        {
            digest[4 * i] = cast(ubyte)(h[i] >> 24);
            digest[4 * i + 1] = cast(ubyte)(h[i] >> 16);
            digest[4 * i + 2] = cast(ubyte)(h[i] >> 8);
            digest[4 * i + 3] = cast(ubyte) h[i];
        }
        return digest;
    }

    private void compress(scope const(ubyte)[] p) @safe pure nothrow @nogc
    in (p.length == 64)
    {
        uint[64] w = void;
        foreach (t; 0 .. 16)
            w[t] = cast(uint) p[4 * t] << 24 | cast(uint) p[4 * t + 1] << 16
                | cast(uint) p[4 * t + 2] << 8 | cast(uint) p[4 * t + 3];
        foreach (t; 16 .. 64)
        {
            immutable x = w[t - 15];
            immutable y = w[t - 2];
            immutable s0 = ror(x, 7) ^ ror(x, 18) ^ (x >> 3);
            immutable s1 = ror(y, 17) ^ ror(y, 19) ^ (y >> 10);
            w[t] = w[t - 16] + s0 + w[t - 7] + s1;
        }

        uint a = h[0], b = h[1], c = h[2], d = h[3];
        uint e = h[4], f = h[5], g = h[6], hh = h[7];
        foreach (t; 0 .. 64)
        {
            immutable S1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25);
            immutable ch = (e & f) ^ (~e & g);
            immutable temp1 = hh + S1 + ch + roundConstants[t] + w[t];
            immutable S0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22);
            immutable maj = (a & b) ^ (a & c) ^ (b & c);
            immutable temp2 = S0 + maj;
            hh = g;
            g = f;
            f = e;
            e = d + temp1;
            d = c;
            c = b;
            b = a;
            a = temp1 + temp2;
        }
        h[0] += a;
        h[1] += b;
        h[2] += c;
        h[3] += d;
        h[4] += e;
        h[5] += f;
        h[6] += g;
        h[7] += hh;
    }
}

/// One-shot SHA-256 of `data`.
ubyte[32] sha256(Bytes data) @safe pure nothrow @nogc
{
    Sha256 s;
    s.update(data);
    return s.finish();
}
