/// Unit tests for the xorshift* generator and the specified shuffle.
module tests.rng_test;

import cardgame.rng;

unittest
{
    // SPEC 25: the first five outputs for seed 7.
    auto r = Rng(7);
    assert(r.next() == 15130880334998875822UL);
    assert(r.next() == 17123930943180875438UL);
    assert(r.next() == 1648209070578717474UL);
    assert(r.next() == 1985375592982671918UL);
    assert(r.next() == 6908966637734145041UL);
}

unittest
{
    // A zero seed is replaced by the constant, so it behaves like that seed.
    auto a = Rng(0);
    auto b = Rng(0x2545F4914F6CDD1DUL);
    foreach (_; 0 .. 5)
        assert(a.next() == b.next());
}

unittest
{
    // below(n) is next() % n.
    auto a = Rng(7);
    auto b = Rng(7);
    assert(a.below(10) == b.next() % 10);
    assert(a.below(1) == 0);
}

unittest
{
    // SPEC 26.12: shuffling eight cards with seed 7 and the second shuffle continuing the stream.
    auto r = Rng(7);
    int[] a = [1, 2, 3, 4, 5, 6, 7, 8];
    int[] b = [9, 10, 11, 12, 13, 14, 15, 16];
    r.shuffle(a);
    r.shuffle(b);
    assert(a == [6, 8, 5, 2, 4, 1, 3, 7]);
    assert(b == [16, 14, 9, 15, 10, 11, 12, 13]);
}

unittest
{
    // Lists of length 0 or 1 consume no randomness.
    auto r = Rng(7);
    int[] empty;
    int[] one = [1];
    r.shuffle(empty);
    r.shuffle(one);
    assert(r.next() == 15130880334998875822UL);
}
