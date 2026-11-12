/// The specified 32-bit linear congruential random number generator.
module chip8.rng;

/**
 * `s = s * 1103515245 + 12345 (mod 2^32)`; the random byte is `(s >> 16) & 0xFF`.
 */
struct Lcg
{
    /// Initial state mandated by the specification.
    enum uint defaultSeed = 0x1234_5678;

    /// Current generator state.
    uint state = defaultSeed;

    /// Advances the generator once and returns the new random byte.
    ubyte next() @safe pure nothrow @nogc
    {
        state = state * 1_103_515_245u + 12_345u;
        return cast(ubyte)(state >> 16);
    }
}

@safe pure nothrow @nogc unittest
{
    Lcg r;
    assert(r.next() == 0x71 && r.state == 0x0b71_9151);
    assert(r.next() == 0x47 && r.state == 0x6f47_bdb6);
    assert(r.next() == 0x1d && r.state == 0x2e1d_6ab7);
}
