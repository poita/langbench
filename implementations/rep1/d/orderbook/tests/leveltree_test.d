module tests.leveltree_test;

import orderbook.leveltree;

unittest // empty tree
{
    auto t = LevelTree(5);
    assert(t.empty && t.total == 0);
    assert(t.lowest == -1 && t.highest == -1);
    assert(t.firstAtOrAfter(0) == -1 && t.lastAtOrBefore(4) == -1);
    assert(t.prefixSum(4) == 0 && t.suffixSum(0) == 0);
}

unittest // zero leaves is legal
{
    auto t = LevelTree(0);
    assert(t.empty && t.lowest == -1);
}

unittest // best, neighbours and sums
{
    auto t = LevelTree(10);
    t.set(2, 5, true);
    t.set(5, 3_000_000_000, true);
    t.set(9, 7, true);
    assert(t.lowest == 2 && t.highest == 9);
    assert(t.firstAtOrAfter(3) == 5 && t.firstAtOrAfter(6) == 9 && t.firstAtOrAfter(10) == -1);
    assert(t.lastAtOrBefore(8) == 5 && t.lastAtOrBefore(1) == -1 && t.lastAtOrBefore(2) == 2);
    assert(t.prefixSum(1) == 0 && t.prefixSum(2) == 5);
    assert(t.prefixSum(5) == 3_000_000_005 && t.prefixSum(9) == 3_000_000_012);
    assert(t.suffixSum(0) == t.total && t.suffixSum(3) == 3_000_000_007);
    assert(t.suffixSum(9) == 7 && t.suffixSum(10) == 0);
    t.set(5, 0, false);
    assert(t.firstAtOrAfter(3) == 9 && t.total == 12);
}

unittest // brute-force cross-check on a non-power-of-two size
{
    enum P = 37;
    auto t = LevelTree(P);
    long[P] q;
    uint seed = 12345;
    foreach (step; 0 .. 2000)
    {
        seed = seed * 1103515245 + 12345;
        const r = (seed >> 8) % P;
        seed = seed * 1103515245 + 12345;
        q[r] = (seed >> 16) % 3 == 0 ? 0 : (seed >> 8) % 1000 + 1;
        t.set(r, q[r], q[r] != 0);
        long lo = -1, hi = -1, s = 0;
        foreach (i; 0 .. P)
            if (q[i])
            {
                if (lo < 0) lo = i;
                hi = i;
            }
        assert(t.lowest == lo && t.highest == hi);
        foreach (i; 0 .. P)
        {
            long f = -1, l = -1, pre = 0;
            foreach (j; i .. P) if (q[j]) { f = j; break; }
            foreach_reverse (j; 0 .. i + 1) if (q[j]) { l = j; break; }
            foreach (j; 0 .. i + 1) pre += q[j];
            assert(t.firstAtOrAfter(i) == f);
            assert(t.lastAtOrBefore(i) == l);
            assert(t.prefixSum(i) == pre);
            assert(t.suffixSum(i) == t.total - pre + q[i]);
        }
    }
}
