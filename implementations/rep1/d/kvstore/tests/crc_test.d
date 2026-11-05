module tests.crc_test;

import tessera.bytes;
import tessera.crc;

unittest
{
    // Test vectors of the specification.
    assert(crc32(null) == 0x00000000);
    assert(crc32(asBytes("a")) == 0xE8B7BE43);
    assert(crc32(asBytes("123456789")) == 0xCBF43926);
    assert(crc32(asBytes("TESSERA1")) == 0x2C9A9B66);
    assert(crc32(asBytes("TESSWAL1")) == 0x7D446716);
    assert(crc32(new ubyte[20]) == 0x0FD59B8D);
    assert(crc32(new ubyte[1024]) == 0xEFB5AF2E);
}

unittest
{
    // Incremental computation agrees with one-shot computation.
    auto data = asBytes("The quick brown fox jumps over the lazy dog");
    Crc32 c;
    c.put(data[0 .. 10]);
    c.put(data[10 .. $]);
    assert(c.value == crc32(data));
    assert(c.value == 0x414FA339);
}
