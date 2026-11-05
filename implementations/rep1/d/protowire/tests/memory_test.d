module memory_test;

import protowire.memory;

@system unittest // ByteBuffer
{
    ByteBuffer b;
    b.putString("ab");
    b.putByte('c');
    b.putUnsigned(0);
    b.putUnsigned(ulong.max);
    b.putByte(' ');
    b.putSigned(long.min);
    b.putByte(' ');
    b.putSigned(-7);
    assert(cast(const(char)[]) b.data == "abc018446744073709551615 -9223372036854775808 -7");
    b.truncate(2);
    assert(b.length == 2);
    b.clear();
    assert(b.length == 0);
}

@system unittest // growth keeps contents
{
    ByteBuffer b;
    foreach (i; 0 .. 10_000)
        b.putByte(cast(ubyte) i);
    assert(b.length == 10_000);
    foreach (i; 0 .. 10_000)
        assert(b.data[i] == cast(ubyte) i);
}

@system unittest // Arena and Vec
{
    Arena a;
    auto v = a.make!(Vec!ulong)();
    foreach (i; 0 .. 100_000)
        v.push(a, i);
    assert(v.len == 100_000);
    assert(v.items[99_999] == 99_999);
    auto z = a.makeArray!ulong(10);
    foreach (i; 0 .. 10)
        assert(z[i] == 0);
    a.reset();
    auto z2 = a.makeArray!ulong(10);
    foreach (i; 0 .. 10)
        assert(z2[i] == 0); // zeroed again on reuse
}
