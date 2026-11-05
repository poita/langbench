/// Unit tests for orderedmap.tree.
module tree_test;

import orderedmap.tree;

private struct Model
{
    // Reference implementation: a plain sorted array.
    long[] keys;
    string[] vals;

    size_t lowerBound(long k) const
    {
        size_t i = 0;
        while (i < keys.length && keys[i] < k) ++i;
        return i;
    }
    bool insert(long k, string v)
    {
        auto i = lowerBound(k);
        if (i < keys.length && keys[i] == k) { vals[i] = v; return false; }
        keys = keys[0 .. i] ~ k ~ keys[i .. $];
        vals = vals[0 .. i] ~ v ~ vals[i .. $];
        return true;
    }
    bool remove(long k)
    {
        auto i = lowerBound(k);
        if (i == keys.length || keys[i] != k) return false;
        keys = keys[0 .. i] ~ keys[i + 1 .. $];
        vals = vals[0 .. i] ~ vals[i + 1 .. $];
        return true;
    }
}

unittest // empty map
{
    OrderedMap m;
    long k;
    const(char)[] v;
    assert(m.empty && m.length == 0);
    assert(!m.min(k) && !m.max(k));
    assert(!m.floor(0, k) && !m.ceil(0, k) && !m.succ(0, k) && !m.pred(0, k));
    assert(!m.get(5, v) && !m.select(0, k));
    assert(m.rank(100) == 0);
    assert(m.keysInRange(long.min, long.max).length == 0);
    assert(!m.remove(1));
    assert(m.checkInvariants());
}

unittest // insert, update, get, remove
{
    OrderedMap m;
    assert(m.insert(5, "five"));
    assert(!m.insert(5, "FIVE"));
    const(char)[] v;
    assert(m.get(5, v) && v == "FIVE");
    assert(m.length == 1 && m.contains(5) && !m.contains(6));
    assert(m.remove(5));
    assert(!m.remove(5));
    assert(m.empty);
}

unittest // neighbours, rank, select
{
    OrderedMap m;
    foreach (k; [10L, 20, 30])
        m.insert(k, "x");
    long r;
    assert(m.floor(25, r) && r == 20);
    assert(m.ceil(25, r) && r == 30);
    assert(m.floor(10, r) && r == 10);
    assert(m.ceil(10, r) && r == 10);
    assert(m.succ(10, r) && r == 20);
    assert(m.pred(10, r) is false);
    assert(m.succ(30, r) is false);
    assert(m.pred(30, r) && r == 20);
    assert(m.rank(20) == 1 && m.rank(21) == 2 && m.rank(5) == 0 && m.rank(99) == 3);
    assert(m.select(2, r) && r == 30);
    assert(!m.select(3, r));
    assert(!m.select(1_000_000_000, r));
    assert(m.min(r) && r == 10);
    assert(m.max(r) && r == 30);
}

unittest // extreme keys never overflow
{
    OrderedMap m;
    m.insert(long.min, "lo");
    m.insert(long.max, "hi");
    m.insert(0, "zero");
    long r;
    assert(!m.succ(long.max, r));
    assert(!m.pred(long.min, r));
    assert(m.floor(long.min + 1, r) && r == long.min);
    assert(m.ceil(1, r) && r == long.max);
    assert(m.succ(long.min, r) && r == 0);
    assert(m.pred(long.max, r) && r == 0);
    assert(m.keysInRange(long.min, long.max) == [long.min, 0, long.max]);
    assert(m.rank(long.max) == 2);
    assert(m.rank(long.min) == 0);
}

unittest // range edge cases
{
    OrderedMap m;
    foreach (k; 1 .. 11)
        m.insert(k * 10, "v");
    assert(m.keysInRange(30, 60) == [30L, 40, 50, 60]);
    assert(m.keysInRange(31, 59) == [40L, 50]);
    assert(m.keysInRange(60, 30).length == 0);
    assert(m.keysInRange(45, 45).length == 0);
    assert(m.keysInRange(50, 50) == [50L]);
    assert(m.keysInRange(-5, 5).length == 0);
    assert(m.keysInRange(long.min, long.max).length == 10);
}

unittest // sorted insertion stays balanced
{
    enum N = 100_000;
    auto m = OrderedMap(N);
    foreach (i; 0 .. N)
        m.insert(i, "v");
    assert(m.length == N);
    assert(m.height <= 24); // 1.44 * log2(N) ≈ 24
    assert(m.checkInvariants());
    foreach_reverse (i; 0 .. N / 2)
        assert(m.remove(i));
    assert(m.length == N - N / 2);
    assert(m.height <= 24);
}

unittest // randomised differential test against a sorted array
{
    import std.random : Mt19937, uniform;
    auto rng = Mt19937(12345);
    OrderedMap m;
    Model ref_;
    foreach (step; 0 .. 6000)
    {
        const k = uniform(-60L, 60L, rng);
        const op = uniform(0, 3, rng);
        if (op == 0)
        {
            const v = "v" ~ cast(char)('a' + step % 26);
            assert(m.insert(k, v) == ref_.insert(k, v));
        }
        else if (op == 1)
            assert(m.remove(k) == ref_.remove(k));
        else
        {
            const(char)[] v;
            const i = ref_.lowerBound(k);
            const has = i < ref_.keys.length && ref_.keys[i] == k;
            assert(m.get(k, v) == has);
            if (has) assert(v == ref_.vals[i]);
        }
        assert(m.length == ref_.keys.length);
        if (step % 50 == 0)
        {
            assert(m.checkInvariants());
            foreach (q; -62L .. 63)
            {
                const i = ref_.lowerBound(q);
                assert(m.rank(q) == i);
                long r;
                assert(m.ceil(q, r) == (i < ref_.keys.length));
                if (i < ref_.keys.length) assert(r == ref_.keys[i]);
                const j = i < ref_.keys.length && ref_.keys[i] == q ? i + 1 : i;
                assert(m.succ(q, r) == (j < ref_.keys.length));
                if (j < ref_.keys.length) assert(r == ref_.keys[j]);
                assert(m.pred(q, r) == (i > 0));
                if (i > 0) assert(r == ref_.keys[i - 1]);
                const fl = i < ref_.keys.length && ref_.keys[i] == q ? i + 1 : i;
                assert(m.floor(q, r) == (fl > 0));
                if (fl > 0) assert(r == ref_.keys[fl - 1]);
            }
            foreach (idx; 0 .. ref_.keys.length)
            {
                long r;
                assert(m.select(idx, r) && r == ref_.keys[idx]);
            }
            assert(m.keysInRange(-20, 20) == ref_.keys[ref_.lowerBound(-20) .. ref_.lowerBound(21)]);
        }
    }
}
