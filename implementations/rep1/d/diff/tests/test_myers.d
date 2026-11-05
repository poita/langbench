/// Unit tests for mdiff.myers: validity and minimality against an LCS table.
module tests.test_myers;

import std.random : Mt19937, uniform;
import mdiff.edit;
import mdiff.myers;
import tests.helpers;

private void checkMinimal(const(int)[] a, const(int)[] b)
{
    auto edits = shortestEdits(a, b);
    immutable c = checkScript(a, b, edits);
    assert(c == a.length + b.length - 2 * lcsLength(a, b), "script is not minimal");
}

unittest // empty inputs
{
    assert(shortestEdits([], []).length == 0);
    assert(cost(shortestEdits([], [1, 2])) == 2);
    assert(cost(shortestEdits([1, 2, 3], [])) == 3);
}

unittest // identical sequences are all keeps
{
    auto e = shortestEdits([4, 5, 6], [4, 5, 6]);
    assert(e.length == 3);
    foreach (x; e)
        assert(x.kind == EditKind.keep);
}

unittest // the example from Myers' paper: abcabba -> cbabac, cost 5
{
    int[] a = [0, 1, 2, 0, 1, 1, 0];
    int[] b = [2, 1, 0, 1, 0, 2];
    assert(checkScript(a, b, shortestEdits(a, b)) == 5);
}

unittest // duplicates
{
    checkMinimal([0, 0, 0, 1, 0, 0], [0, 1, 0, 0, 0, 1]);
}

unittest // completely disjoint: the worst case, cost N + M
{
    int[] a = new int[50], b = new int[70];
    foreach (i, ref v; a) v = cast(int) i;
    foreach (i, ref v; b) v = cast(int) (1000 + i);
    assert(checkScript(a, b, shortestEdits(a, b)) == 120);
}

unittest // exhaustive: every pair of sequences over {0,1,2} up to length 5
{
    int[][] all = [[]];
    foreach (len; 1 .. 6)
    {
        size_t total = 1;
        foreach (_; 0 .. len) total *= 3;
        foreach (code; 0 .. total)
        {
            auto s = new int[len];
            auto c = code;
            foreach (ref v; s) { v = cast(int) (c % 3); c /= 3; }
            all ~= s;
        }
    }
    foreach (a; all)
        foreach (b; all)
            checkMinimal(a, b);
}

unittest // random pairs over several alphabet sizes
{
    auto rng = Mt19937(12345);
    foreach (iter; 0 .. 3000)
    {
        immutable alphabet = [2, 3, 5, 20, 1000][iter % 5];
        auto a = randomSeq(rng, uniform(0, 60, rng), alphabet);
        auto b = randomSeq(rng, uniform(0, 60, rng), alphabet);
        checkMinimal(a, b);
    }
}

unittest // random edits of a base sequence (small D, long common parts)
{
    auto rng = Mt19937(777);
    foreach (iter; 0 .. 200)
    {
        auto a = randomSeq(rng, uniform(100, 400, rng), 8);
        int[] b = a.dup;
        foreach (_; 0 .. uniform(0, 12, rng))
        {
            if (b.length && uniform(0, 2, rng))
            {
                immutable p = uniform(0, b.length, rng);
                b = b[0 .. p] ~ b[p + 1 .. $];
            }
            else
            {
                immutable p = uniform(0, b.length + 1, rng);
                b = b[0 .. p] ~ [uniform(0, 8, rng)] ~ b[p .. $];
            }
        }
        checkMinimal(a, b);
    }
}

unittest // larger inputs stay exact and fast (D = 3000 worst case)
{
    int[] a = new int[1500], b = new int[1500];
    foreach (i; 0 .. 1500) { a[i] = i; b[i] = 5000 + i; }
    assert(cost(shortestEdits(a, b)) == 3000);
}
