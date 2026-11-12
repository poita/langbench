/**
 * Ordering and sign conventions that make eigenvectors and singular
 * vectors unique.
 */
module linalg.ordering;

import std.math : abs;

/**
 * Indices `0 .. values.length` sorted by value (ascending, or descending
 * when `descending`), ties broken by the smaller original index.
 */
size_t[] sortedOrder(const double[] values, bool descending = false) @safe pure
{
    import std.algorithm : sort;
    import std.range : iota;
    import std.array : array;

    auto idx = iota(values.length).array;
    if (descending)
        idx.sort!((a, b) => values[a] > values[b] || (values[a] == values[b] && a < b));
    else
        idx.sort!((a, b) => values[a] < values[b] || (values[a] == values[b] && a < b));
    return idx;
}

/**
 * True when column `v` should be negated: its entry of largest magnitude
 * (the smallest index among ties) is negative. An all-zero column is left
 * alone.
 */
bool needsNegation(const double[] v) @safe pure nothrow @nogc
{
    double best = 0.0;
    size_t at = 0;
    foreach (i, x; v)
    {
        const a = abs(x);
        if (a > best)
        {
            best = a;
            at = i;
        }
    }
    return best > 0.0 && v[at] < 0.0;
}

unittest
{
    assert(sortedOrder([3.0, 1.0, 3.0, 2.0]) == [1, 3, 0, 2]);
    assert(sortedOrder([3.0, 1.0, 3.0, 2.0], true) == [0, 2, 3, 1]);
}

unittest
{
    assert(needsNegation([-0.8, 0.5]));
    assert(!needsNegation([0.8, -0.5]));
    assert(needsNegation([0.5, -0.5, 0.1]) == false);   // first of equal maxima is +
    assert(needsNegation([-0.5, 0.5]));
    assert(!needsNegation([0.0, 0.0]));
}
