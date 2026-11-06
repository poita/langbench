/// The Luby restart sequence.
module sat.luby;

/**
 * Element `i` (0-based) of the Luby sequence scaled by base `y`:
 * `1, 1, 2, 1, 1, 2, 4, 1, 1, 2, ...` raised as `y ^ k`.
 */
long luby(long y, long i) pure nothrow @safe @nogc
in (y >= 1 && i >= 0)
{
    long size = 1;
    int seq = 0;
    while (size < i + 1)
    {
        seq++;
        size = 2 * size + 1;
    }
    while (size - 1 != i)
    {
        size = (size - 1) >> 1;
        seq--;
        i %= size;
    }
    long r = 1;
    foreach (_; 0 .. seq)
        r *= y;
    return r;
}
