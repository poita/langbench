/// The Luby restart sequence.
module sat.luby;

/**
 * The `i`-th (0-based) element of the Luby sequence scaled by base `y`:
 * `1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ...` for `y == 2`, i.e. `y ^^ k` for the
 * matching exponent `k`.
 */
long luby(long y, long i) pure nothrow @nogc @safe
in (y >= 1 && i >= 0)
{
    long size = 1;
    long seq = 0;
    while (size < i + 1)
    {
        ++seq;
        size = 2 * size + 1;
    }
    while (size - 1 != i)
    {
        size = (size - 1) >> 1;
        --seq;
        i %= size;
    }
    long r = 1;
    foreach (_; 0 .. seq)
        r *= y;
    return r;
}

///
@safe pure nothrow @nogc unittest
{
    static immutable long[] expected = [1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8, 1];
    foreach (i, e; expected)
        assert(luby(2, i) == e);
    assert(luby(3, 2) == 3);
}
