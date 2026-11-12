/**
 * SHA-256 (FIPS 180-4), implemented from scratch.
 *
 * Use `sha256` for one-shot hashing or the `Sha256` struct to hash data
 * incrementally. `Sha256` is a plain value type: copying it copies the
 * hashing state, which is what lets `webhooks.hmac` reuse a keyed prefix.
 */
module webhooks.sha256;

/// Size of a SHA-256 digest in bytes.
enum size_t sha256DigestSize = 32;
/// Size of a SHA-256 input block in bytes.
enum size_t sha256BlockSize = 64;

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

private pure nothrow @safe @nogc
uint ror(uint x, uint n)
{
    return (x >> n) | (x << (32 - n));
}

/// Incremental SHA-256 hasher.
struct Sha256
{
    private uint[8] state = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    private ubyte[64] buffer;
    private size_t buffered; // bytes currently held in `buffer`
    private ulong totalBytes; // message length so far

    /// Appends `data` to the message.
    void put(scope const(ubyte)[] data) pure nothrow @safe @nogc
    {
        totalBytes += data.length;
        if (buffered > 0)
        {
            immutable take = data.length < 64 - buffered ? data.length : 64 - buffered;
            buffer[buffered .. buffered + take] = data[0 .. take];
            buffered += take;
            data = data[take .. $];
            if (buffered < 64)
                return;
            compress(buffer[]);
            buffered = 0;
        }
        while (data.length >= 64)
        {
            compress(data[0 .. 64]);
            data = data[64 .. $];
        }
        buffer[0 .. data.length] = data[];
        buffered = data.length;
    }

    /// ditto
    void put(scope const(char)[] text) pure nothrow @trusted @nogc
    {
        put(cast(const(ubyte)[]) text);
    }

    /// Applies the padding and returns the 32-byte digest. The hasher must
    /// not be used afterwards (copy it first if you need to continue).
    ubyte[32] finish() pure nothrow @safe @nogc
    {
        immutable ulong bitLength = totalBytes * 8;
        ubyte[72] tail; // 0x80, zeros, 8-byte length: at most 64 + 8 bytes
        tail[0] = 0x80;
        immutable zeros = (buffered < 56 ? 55 - buffered : 119 - buffered);
        foreach (i; 0 .. 8)
            tail[1 + zeros + i] = cast(ubyte)(bitLength >> (56 - 8 * i));
        immutable saved = totalBytes;
        put(tail[0 .. 1 + zeros + 8]);
        totalBytes = saved;
        assert(buffered == 0);

        ubyte[32] digest;
        foreach (i, w; state)
        {
            digest[4 * i] = cast(ubyte)(w >> 24);
            digest[4 * i + 1] = cast(ubyte)(w >> 16);
            digest[4 * i + 2] = cast(ubyte)(w >> 8);
            digest[4 * i + 3] = cast(ubyte) w;
        }
        return digest;
    }

    private void compress(scope const(ubyte)[] block) pure nothrow @safe @nogc
    in (block.length == 64)
    {
        uint[64] w = void;
        foreach (t; 0 .. 16)
            w[t] = (cast(uint) block[4 * t] << 24) | (cast(uint) block[4 * t + 1] << 16)
                | (cast(uint) block[4 * t + 2] << 8) | cast(uint) block[4 * t + 3];
        foreach (t; 16 .. 64)
        {
            immutable s0 = ror(w[t - 15], 7) ^ ror(w[t - 15], 18) ^ (w[t - 15] >> 3);
            immutable s1 = ror(w[t - 2], 17) ^ ror(w[t - 2], 19) ^ (w[t - 2] >> 10);
            w[t] = w[t - 16] + s0 + w[t - 7] + s1;
        }

        uint a = state[0], b = state[1], c = state[2], d = state[3];
        uint e = state[4], f = state[5], g = state[6], h = state[7];
        foreach (t; 0 .. 64)
        {
            immutable bigS1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25);
            immutable ch = (e & f) ^ (~e & g);
            immutable temp1 = h + bigS1 + ch + roundConstants[t] + w[t];
            immutable bigS0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22);
            immutable maj = (a & b) ^ (a & c) ^ (b & c);
            immutable temp2 = bigS0 + maj;
            h = g;
            g = f;
            f = e;
            e = d + temp1;
            d = c;
            c = b;
            b = a;
            a = temp1 + temp2;
        }
        state[0] += a;
        state[1] += b;
        state[2] += c;
        state[3] += d;
        state[4] += e;
        state[5] += f;
        state[6] += g;
        state[7] += h;
    }
}

/// One-shot SHA-256 of `data`.
ubyte[32] sha256(scope const(ubyte)[] data) pure nothrow @safe @nogc
{
    Sha256 h;
    h.put(data);
    return h.finish();
}

///
@safe unittest
{
    import webhooks.hex : toHex;

    assert(toHex(sha256([])) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert(toHex(sha256(cast(const(ubyte)[]) "abc"))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

@safe unittest
{
    import webhooks.hex : toHex;

    // FIPS 180-4 two-block message.
    assert(toHex(sha256(cast(const(ubyte)[]) "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
}

// Lengths around the padding boundaries must agree between one-shot and
// incremental hashing, and the million-'a' vector must hold.
@safe unittest
{
    import webhooks.hex : toHex;

    auto data = new ubyte[200];
    foreach (i, ref b; data)
        b = cast(ubyte)(i * 7 + 3);
    foreach (n; 0 .. 200)
    {
        Sha256 h;
        size_t pos = 0;
        size_t step = 1;
        while (pos < n)
        {
            immutable end = pos + step < n ? pos + step : n;
            h.put(data[pos .. end]);
            pos = end;
            step = step % 13 + 1;
        }
        assert(h.finish() == sha256(data[0 .. n]));
    }

    auto million = new ubyte[1_000_000];
    million[] = 'a';
    assert(toHex(sha256(million)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}
