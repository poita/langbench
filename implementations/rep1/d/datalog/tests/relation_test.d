module tests.relation_test;

import datalog.relation;

unittest
{
    auto r = new Relation(2);
    assert(r.length == 0);
    assert(!r.contains([1, 2]));
    assert(r.insert([1, 2]));
    assert(!r.insert([1, 2]));
    assert(r.insert([2, 1]));
    assert(r.length == 2);
    assert(r.contains([2, 1]));
    assert(!r.contains([2, 2]));
    assert(r[0] == [1, 2] && r[1] == [2, 1]);
}

unittest
{
    // The hash set survives many growths.
    auto r = new Relation(2);
    foreach (i; 0 .. 5000)
        foreach (j; 0 .. 3)
            assert(r.insert([i, j]));
    assert(r.length == 15_000);
    foreach (i; 0 .. 5000)
        foreach (j; 0 .. 3)
            assert(r.contains([i, j]) && !r.insert([i, j]));
    assert(!r.contains([5000, 0]));
}

private uint[] chain(Index idx, const(Value)[] key, size_t limit = noPos)
{
    uint[] result;
    for (auto p = idx.first(key); p < limit; p = idx.next[p])
        result ~= p;
    return result;
}

unittest
{
    auto r = new Relation(3);
    r.insert([1, 10, 100]);
    r.insert([2, 10, 200]);
    r.insert([1, 20, 300]);
    r.insert([1, 10, 400]);

    auto byFirst = r.index(0b001);
    assert(r.index(0b001) is byFirst); // same mask, same index
    assert(r.findIndex(0b010) is null);
    byFirst.update();
    assert(chain(byFirst, [1]) == [0, 2, 3]);
    assert(chain(byFirst, [2]) == [1]);
    assert(chain(byFirst, [3]) == []);

    auto byFirstThird = r.index(0b101);
    byFirstThird.update();
    assert(chain(byFirstThird, [1, 400]) == [3]);
    assert(chain(byFirstThird, [1, 200]) == []);
}

unittest
{
    // Incremental update: only new tuples are indexed, chains stay ascending.
    auto r = new Relation(2);
    auto idx = r.index(0b01);
    r.insert([1, 1]);
    r.insert([2, 1]);
    idx.update();
    assert(chain(idx, [1]) == [0]);
    r.insert([1, 2]);
    r.insert([1, 3]);
    assert(chain(idx, [1]) == [0]); // not visible until updated
    idx.update();
    assert(chain(idx, [1]) == [0, 2, 3]);
    assert(chain(idx, [1], 3) == [0, 2]); // limit cuts the chain at a snapshot
}

unittest
{
    auto r = new Relation(1);
    auto idx = r.index(1);
    foreach (i; 0 .. 10_000)
        r.insert([i % 1000]);
    idx.update();
    foreach (k; 0 .. 1000)
        assert(chain(idx, [k]) == [k]); // duplicates were rejected, one tuple each
    assert(r.length == 1000);
}
