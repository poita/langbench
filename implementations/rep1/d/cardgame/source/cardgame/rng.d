/// The deterministic 64-bit xorshift* generator of SPEC.md section 25.
module cardgame.rng;

/// xorshift* generator; all arithmetic is modulo 2^64.
struct Rng
{
    private ulong state = 0x2545F4914F6CDD1DUL;

    /// Seed the generator; a zero seed is replaced by a fixed constant.
    this(ulong seed) pure nothrow @safe @nogc
    {
        state = seed == 0 ? 0x2545F4914F6CDD1DUL : seed;
    }

    /// Next raw 64-bit value.
    ulong next() pure nothrow @safe @nogc
    {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        return state * 0x2545F4914F6CDD1DUL;
    }

    /// A value in `[0, n)` for `n >= 1`.
    ulong below(ulong n) pure nothrow @safe @nogc
    {
        return next() % n;
    }

    /// Fisher-Yates shuffle as specified: i from k-1 down to 1.
    void shuffle(T)(T[] a)
    {
        if (a.length < 2) return;
        for (size_t i = a.length - 1; i >= 1; --i)
        {
            immutable j = cast(size_t) below(i + 1);
            auto t = a[i]; a[i] = a[j]; a[j] = t;
        }
    }
}

unittest
{
    auto r = Rng(7);
    assert(r.next() == 15130880334998875822UL);
    assert(r.next() == 17123930943180875438UL);
    assert(r.next() == 1648209070578717474UL);
    assert(r.next() == 1985375592982671918UL);
    assert(r.next() == 6908966637734145041UL);
}

unittest
{
    int[] a = [1];
    auto r = Rng(1);
    r.shuffle(a);
    assert(a == [1]);
    auto r0 = Rng(0), r1 = Rng(0x2545F4914F6CDD1DUL);
    assert(r0.next() == r1.next());
}
