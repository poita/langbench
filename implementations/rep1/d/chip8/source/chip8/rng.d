/// The deterministic random number generator used by `CXNN`.
module chip8.rng;

import chip8.constants : rngSeed;

/// Advance the LCG state once: `s = s * 1103515245 + 12345 (mod 2^32)`.
pragma(inline, true)
uint rngNext(uint s) pure nothrow @safe @nogc
{
    return s * 1103515245u + 12345u;
}

/// Extract the random byte from an LCG state: bits 16..23.
pragma(inline, true)
ubyte rngByte(uint s) pure nothrow @safe @nogc
{
    return cast(ubyte)(s >> 16);
}

/// A small range-like wrapper around the generator, handy outside the hot loop.
struct Rng
{
    /// Current state.
    uint state = rngSeed;

    /// Advance and return the next random byte.
    ubyte next() pure nothrow @safe @nogc
    {
        state = rngNext(state);
        return rngByte(state);
    }
}
