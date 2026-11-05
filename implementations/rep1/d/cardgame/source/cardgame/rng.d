/**
 * The 64-bit xorshift* pseudo-random generator of SPEC section 25.
 */
module cardgame.rng;

/// Deterministic generator; all arithmetic is modulo 2^64.
struct Rng
{
    private ulong state;

    /// Seed the generator; a zero seed is replaced by a fixed constant.
    this(ulong seed) @safe pure nothrow @nogc
    {
        state = seed == 0 ? 0x2545F4914F6CDD1DUL : seed;
    }

    /// Next raw 64-bit value.
    ulong next() @safe pure nothrow @nogc
    {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        return state * 0x2545F4914F6CDD1DUL;
    }

    /// Uniform-ish value in `[0, n)`; `n` must be at least 1.
    ulong below(ulong n) @safe pure nothrow @nogc
    {
        return next() % n;
    }

    /// Fisher-Yates shuffle exactly as the specification describes it.
    void shuffle(T)(T[] list)
    {
        if (list.length < 2)
            return;
        for (size_t i = list.length - 1; i >= 1; i--)
        {
            immutable j = cast(size_t) below(i + 1);
            immutable tmp = list[i];
            list[i] = list[j];
            list[j] = tmp;
        }
    }
}
