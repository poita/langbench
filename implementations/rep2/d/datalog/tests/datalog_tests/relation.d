module datalog_tests.relation;

import datalog.relation;

unittest // insert, dedup, contains, order
{
    auto r = new Relation(2);
    assert(r.insert([1, 2]));
    assert(r.insert([2, 1]));
    assert(!r.insert([1, 2]));
    assert(r.length == 2);
    assert(r.contains([2, 1]) && !r.contains([2, 2]));
    assert(r.tuple(0) == [1, 2] && r.tuple(1) == [2, 1]);
}

unittest // growth keeps everything findable
{
    auto r = new Relation(3);
    foreach (i; 0 .. 5000u)
        assert(r.insert([i, i * 7, i % 13]));
    foreach (i; 0 .. 5000u)
    {
        assert(r.contains([i, i * 7, i % 13]));
        assert(!r.insert([i, i * 7, i % 13]));
    }
    assert(r.length == 5000);
}

unittest // index chains are ascending and extend incrementally
{
    auto r = new Relation(2);
    foreach (i; 0 .. 100u) r.insert([i % 4, i]);
    auto ix = r.index(0b01);
    assert(r.index(0b01) is ix);
    ix.update();
    uint[] got;
    uint[1] key = [2];
    for (uint p = ix.find(key.ptr); p != Index.none; p = ix.next(p)) got ~= p;
    assert(got.length == 25 && got[0] == 2 && got[1] == 6);
    foreach (i; 1 .. got.length) assert(got[i] > got[i - 1]);

    // add more tuples, update, see them
    r.insert([2, 1000]);
    ix.update();
    got = null;
    for (uint p = ix.find(key.ptr); p != Index.none; p = ix.next(p)) got ~= p;
    assert(got.length == 26 && r.tuple(got[$ - 1]) == [2, 1000]);

    uint[1] missing = [9];
    assert(ix.find(missing.ptr) == Index.none);
}

unittest // multi-column index
{
    auto r = new Relation(3);
    r.insert([1, 2, 3]);
    r.insert([1, 9, 3]);
    r.insert([1, 2, 4]);
    auto ix = r.index(0b101);
    ix.update();
    uint[2] key = [1, 3];
    uint n = 0;
    for (uint p = ix.find(key.ptr); p != Index.none; p = ix.next(p)) ++n;
    assert(n == 2);
}
