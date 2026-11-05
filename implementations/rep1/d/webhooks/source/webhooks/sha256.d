/**
 * SHA-256 (FIPS 180-4), implemented from scratch.
 *
 * `Sha256` is an incremental hasher. It is a plain value type: copying it
 * copies the full state, which is how `webhooks.hmac` reuses the precomputed
 * ipad/opad states.
 */
module webhooks.sha256;

private immutable uint[8] initialState = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

private immutable uint[64] roundConstants = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// Size of a SHA-256 digest in bytes.
enum size_t sha256DigestSize = 32;
/// Size of a SHA-256 input block in bytes.
enum size_t sha256BlockSize = 64;

/// Incremental SHA-256 hasher.
struct Sha256
{
    private uint[8] state = initialState;
    private ubyte[64] block;
    private uint blockLen;
    private ulong totalLen;

    /// Absorbs `data`. Full blocks are compressed straight from `data`.
    void put(scope const(ubyte)[] data) @safe pure nothrow @nogc
    {
        totalLen += data.length;
        size_t pos = 0;
        if (blockLen != 0)
        {
            immutable take = data.length < 64 - blockLen ? data.length : 64 - blockLen;
            block[blockLen .. blockLen + take] = data[0 .. take];
            blockLen += cast(uint) take;
            pos = take;
            if (blockLen < 64)
                return;
            compress(state, block[]);
            blockLen = 0;
        }
        while (data.length - pos >= 64)
        {
            compress(state, data[pos .. pos + 64]);
            pos += 64;
        }
        immutable rest = data.length - pos;
        if (rest != 0)
        {
            block[0 .. rest] = data[pos .. $];
            blockLen = cast(uint) rest;
        }
    }

    /// Pads, finishes and returns the 32-byte digest. The hasher must not be
    /// reused afterwards (copy it first if you need to continue).
    ubyte[32] finish() @safe pure nothrow @nogc
    {
        immutable ulong bitLen = totalLen * 8;
        block[blockLen++] = 0x80;
        if (blockLen > 56)
        {
            block[blockLen .. 64] = 0;
            compress(state, block[]);
            blockLen = 0;
        }
        block[blockLen .. 56] = 0;
        foreach (i; 0 .. 8)
            block[56 + i] = cast(ubyte)(bitLen >> (56 - 8 * i));
        compress(state, block[]);
        blockLen = 0;

        ubyte[32] digest;
        foreach (i; 0 .. 8)
            foreach (j; 0 .. 4)
                digest[4 * i + j] = cast(ubyte)(state[i] >> (24 - 8 * j));
        return digest;
    }
}

/// One-shot SHA-256 of `data`.
ubyte[32] sha256Of(scope const(ubyte)[] data) @safe pure nothrow @nogc
{
    Sha256 h;
    h.put(data);
    return h.finish();
}

private uint ror(uint x, uint n) @safe pure nothrow @nogc
{
    return (x >> n) | (x << (32 - n));
}

/// Compresses exactly one 64-byte block into `state`.
private void compress(ref uint[8] state, scope const(ubyte)[] chunk) @safe pure nothrow @nogc
in (chunk.length >= 64)
{
    uint[64] w = void;
    foreach (t; 0 .. 16)
    {
        w[t] = (cast(uint) chunk[4 * t] << 24) | (cast(uint) chunk[4 * t + 1] << 16)
            | (cast(uint) chunk[4 * t + 2] << 8) | cast(uint) chunk[4 * t + 3];
    }
    foreach (t; 16 .. 64)
    {
        immutable a = w[t - 15];
        immutable b = w[t - 2];
        immutable s0 = ror(a, 7) ^ ror(a, 18) ^ (a >> 3);
        immutable s1 = ror(b, 17) ^ ror(b, 19) ^ (b >> 10);
        w[t] = w[t - 16] + s0 + w[t - 7] + s1;
    }

    uint a = state[0], b = state[1], c = state[2], d = state[3];
    uint e = state[4], f = state[5], g = state[6], h = state[7];
    foreach (t; 0 .. 64)
    {
        immutable S1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25);
        immutable ch = (e & f) ^ (~e & g);
        immutable temp1 = h + S1 + ch + roundConstants[t] + w[t];
        immutable S0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22);
        immutable maj = (a & b) ^ (a & c) ^ (b & c);
        immutable temp2 = S0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }
    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}
