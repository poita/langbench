/**
 * The Luby restart sequence.
 */
module sat.luby;

@safe pure nothrow @nogc:

/**
 * Element `i` (0-based) of the Luby sequence scaled to base 2:
 * 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ...
 *
 * Computed with integer arithmetic only (the same recurrence as MiniSat).
 */
long luby2(long i)
{
    long size = 1;
    int seq = 0;
    while (size < i + 1)
    {
        ++seq;
        size = 2 * size + 1;
    }
    while (size - 1 != i)
    {
        size = (size - 1) >> 1;
        --seq;
        i = i % size;
    }
    return 1L << seq;
}
