/// The 32-bit linear congruential generator used by `CXNN`.
module chip8.rng;

/// Initial RNG state.
enum uint defaultSeed = 0x1234_5678;

/// LCG: `s = s * 1103515245 + 12345 (mod 2^32)`; output is bits 16..23.
struct Lcg
{
    /// Current state.
    uint state = defaultSeed;

    /// Advance once and return the next random byte.
    ubyte next() @safe pure nothrow @nogc
    {
        state = state * 1_103_515_245u + 12_345u;
        return cast(ubyte)(state >> 16);
    }
}

@safe pure nothrow @nogc unittest
{
    Lcg r;
    assert(r.next() == 0x71 && r.state == 0x0b719151);
    assert(r.next() == 0x47 && r.state == 0x6f47bdb6);
    assert(r.next() == 0x1d && r.state == 0x2e1d6ab7);
}
