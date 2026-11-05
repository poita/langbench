/// Unit tests for gitrepo.sha1.
module unit.test_sha1;

import gitrepo.oid;
import gitrepo.sha1;

private string hex(const(ubyte)[] d)
{
    ObjectId id;
    id.bytes[] = d[0 .. 20];
    return id.toString();
}

unittest
{
    // FIPS 180 test vectors
    assert(hex(sha1Of(cast(const(ubyte)[]) "abc")) == "a9993e364706816aba3e25717850c26c9cd0d89d");
    assert(hex(sha1Of([])) == "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    assert(hex(sha1Of(cast(const(ubyte)[]) "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
        == "84983e441c3bd26ebaae4aa1f95129e5e54670f1");
}

unittest
{
    // the blob "one file\n" has a well-known id
    assert(hex(sha1Of(cast(const(ubyte)[]) "blob 9\0one file\n")) == "b7814cae2e925fe74c6cd5816462fff515ccb256");
}

unittest
{
    // one million 'a', fed in uneven chunks
    Sha1 s;
    ubyte[1000] chunk = 'a';
    size_t fed = 0;
    size_t step = 1;
    while (fed < 1_000_000)
    {
        auto n = step < 1000 ? step : 1000;
        if (n > 1_000_000 - fed)
            n = 1_000_000 - fed;
        s.put(chunk[0 .. n]);
        fed += n;
        step = step * 3 % 997 + 1;
    }
    assert(hex(s.finish()) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f");
}
