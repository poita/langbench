module sat.luby_test;

import sat.luby;

unittest
{
    immutable long[] expected = [1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8,
        1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8, 16];
    foreach (i, e; expected)
        assert(luby2(i) == e);
}
