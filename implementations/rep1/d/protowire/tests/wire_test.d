module wire_test;

import protowire.wire;

@system unittest // varint round trip and minimality
{
    ubyte[16] buf;
    foreach (v; [0UL, 1, 127, 128, 300, 16383, 16384, uint.max, ulong.max / 2, ulong.max])
    {
        auto end = putVarint(buf.ptr, v);
        const n = end - buf.ptr;
        assert(n == varintLength(v));
        size_t pos = 0;
        ulong back;
        assert(readVarint(buf.ptr, pos, n, 10, back));
        assert(back == v && pos == n);
    }
}

@system unittest // known encodings
{
    ubyte[16] buf;
    assert(putVarint(buf.ptr, 300) - buf.ptr == 2 && buf[0] == 0xac && buf[1] == 0x02);
    assert(putVarint(buf.ptr, ulong.max) - buf.ptr == 10 && buf[9] == 0x01);
}

@system unittest // non-minimal, overlong-but-legal and illegal varints
{
    ulong v;
    size_t pos = 0;
    immutable ubyte[] nonMinimal = [0x81, 0x00];
    assert(readVarint(nonMinimal.ptr, pos, 2, 10, v) && v == 1);

    // Bits beyond 63 are discarded.
    immutable ubyte[] big = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f];
    pos = 0;
    assert(readVarint(big.ptr, pos, 10, 10, v) && v == ulong.max);
    immutable ubyte[] wrap = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02];
    pos = 0;
    assert(readVarint(wrap.ptr, pos, 10, 10, v) && v == 0);

    // Eleven bytes, or cut short, or too long for a 5-byte limit.
    immutable ubyte[] eleven = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00];
    pos = 0;
    assert(!readVarint(eleven.ptr, pos, 11, 10, v));
    pos = 0;
    assert(!readVarint(nonMinimal.ptr, pos, 1, 10, v));
    immutable ubyte[] six = [0x80, 0x80, 0x80, 0x80, 0x80, 0x00];
    pos = 0;
    assert(!readVarint(six.ptr, pos, 6, 5, v));
}

@safe unittest // zigzag
{
    assert(zigzag32(0) == 0 && zigzag32(-1) == 1 && zigzag32(1) == 2);
    assert(zigzag32(int.min) == uint.max);
    assert(zigzag64(long.min) == ulong.max && zigzag64(-2) == 3);
    foreach (v; [0, 1, -1, 12345, -12345, int.max, int.min])
        assert(unzigzag32(zigzag32(v)) == v);
    foreach (v; [0L, 1, -1, long.max, long.min])
        assert(unzigzag64(zigzag64(v)) == v);
}

@safe unittest // varint lengths
{
    assert(varintLength(0) == 1 && varintLength(127) == 1 && varintLength(128) == 2);
    assert(varintLength(ulong.max) == 10);
}
