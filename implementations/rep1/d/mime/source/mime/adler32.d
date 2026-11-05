/// Adler-32 checksum.
module mime.adler32;

/// Computes Adler-32 of `data`. The modulo is deferred to every 5552 bytes
/// (the zlib bound), which gives the same result as reducing per byte.
uint adler32(scope const(ubyte)[] data) @safe pure nothrow @nogc
{
    enum uint mod = 65_521;
    enum size_t nmax = 5552;
    uint a = 1, b = 0;
    size_t i = 0;
    while (i < data.length)
    {
        immutable end = i + nmax < data.length ? i + nmax : data.length;
        foreach (x; data[i .. end])
        {
            a += x;
            b += a;
        }
        a %= mod;
        b %= mod;
        i = end;
    }
    return (b << 16) | a;
}
