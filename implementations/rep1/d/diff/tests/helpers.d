/// Shared helpers for the unit tests (no tests of its own).
module tests.helpers;

import std.random : Mt19937, uniform;
import mdiff.edit;

/// Length of the longest common subsequence, by the classic O(N·M) table.
size_t lcsLength(const(int)[] a, const(int)[] b)
{
    auto prev = new size_t[b.length + 1];
    auto cur = new size_t[b.length + 1];
    foreach (x; a)
    {
        foreach (j, y; b)
        {
            if (x == y)
                cur[j + 1] = prev[j] + 1;
            else
                cur[j + 1] = prev[j + 1] > cur[j] ? prev[j + 1] : cur[j];
        }
        auto t = prev; prev = cur; cur = t;
    }
    return prev[b.length];
}

/// Asserts that `edits` is a valid script for a -> b and returns its cost.
size_t checkScript(const(int)[] a, const(int)[] b, const(Edit)[] edits)
{
    int[] ra, rb;
    size_t cost;
    foreach (e; edits)
    {
        final switch (e.kind)
        {
        case EditKind.keep:
            assert(e.index == cast(int) ra.length);
            ra ~= a[e.index];
            rb ~= a[e.index];
            break;
        case EditKind.remove:
            assert(e.index == cast(int) ra.length);
            ra ~= a[e.index];
            ++cost;
            break;
        case EditKind.insert:
            assert(e.index == cast(int) rb.length);
            rb ~= b[e.index];
            ++cost;
            break;
        }
    }
    assert(ra == a, "script does not reproduce A");
    assert(rb == b, "script does not reproduce B");
    return cost;
}

/// A random sequence of `len` ids drawn from `alphabet` symbols.
int[] randomSeq(ref Mt19937 rng, size_t len, int alphabet)
{
    auto s = new int[len];
    foreach (ref v; s)
        v = uniform(0, alphabet, rng);
    return s;
}
