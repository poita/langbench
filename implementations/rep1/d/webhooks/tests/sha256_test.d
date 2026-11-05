module sha256_test;

import webhooks.hex : toHex;
import webhooks.sha256;

@("sha256: empty and abc")
unittest
{
    assert(toHex(sha256Of([])[]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert(toHex(sha256Of(cast(const(ubyte)[]) "abc")[]) ==
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

@("sha256: two-block message")
unittest
{
    auto msg = cast(const(ubyte)[]) "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    assert(toHex(sha256Of(msg)[]) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
}

@("sha256: incremental equals one-shot at every split and padding boundary")
unittest
{
    foreach (len; [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 128, 200])
    {
        auto data = new ubyte[len];
        foreach (i, ref b; data)
            b = cast(ubyte)(i * 7 + 3);
        immutable expected = sha256Of(data);
        foreach (split; 0 .. len + 1)
        {
            Sha256 h;
            h.put(data[0 .. split]);
            h.put(data[split .. $]);
            assert(h.finish() == expected);
        }
    }
}

@("sha256: one million 'a'")
unittest
{
    Sha256 h;
    auto chunk = new ubyte[1000];
    chunk[] = 'a';
    foreach (_; 0 .. 1000)
        h.put(chunk);
    assert(toHex(h.finish()[]) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

@("sha256: copying a hasher copies its state")
unittest
{
    Sha256 a;
    a.put(cast(const(ubyte)[]) "ab");
    auto b = a;
    a.put(cast(const(ubyte)[]) "c");
    assert(a.finish() == sha256Of(cast(const(ubyte)[]) "abc"));
    b.put(cast(const(ubyte)[]) "d");
    assert(b.finish() == sha256Of(cast(const(ubyte)[]) "abd"));
}
