module relation_test;

import datalog.relation;

unittest // insert deduplicates and keeps insertion order
{
    auto r = new Relation(2);
    assert(r.insert([1, 2]));
    assert(r.insert([2, 1]));
    assert(!r.insert([1, 2]));
    assert(r.length == 2);
    assert(r[0] == [1, 2] && r[1] == [2, 1]);
    assert(r.contains([2, 1]));
    assert(!r.contains([2, 2]));
}

unittest // growth keeps membership intact
{
    auto r = new Relation(2);
    foreach (i; 0 .. 5000)
        assert(r.insert([i, i * 7]));
    foreach (i; 0 .. 5000)
    {
        assert(r.contains([i, i * 7]));
        assert(!r.insert([i, i * 7]));
    }
    assert(r.length == 5000);
}

unittest // index chains are ascending and extended incrementally
{
    auto r = new Relation(2);
    auto ix = r.indexOn(0b01);
    assert(ix is r.indexOn(0b01));
    foreach (i; 0 .. 100)
        r.insert([i % 3, i]);
    ix.update();
    uint[] got;
    for (uint p = ix.find([1]); p != none; p = ix.next[p])
        got ~= p;
    assert(got.length == 33);
    foreach (i; 1 .. got.length)
        assert(got[i - 1] < got[i]);
    foreach (p; got)
        assert(r[p][0] == 1);

    r.insert([1, 1000]);
    assert(ix.find([7]) == none);
    ix.update();
    got = null;
    for (uint p = ix.find([1]); p != none; p = ix.next[p])
        got ~= p;
    assert(got.length == 34 && r[got[$ - 1]][1] == 1000);
}

unittest // multi-column index
{
    auto r = new Relation(3);
    r.insert([1, 2, 3]);
    r.insert([1, 9, 3]);
    r.insert([1, 2, 4]);
    auto ix = r.indexOn(0b101);
    ix.update();
    assert(ix.columns == [0u, 2u]);
    uint n;
    for (uint p = ix.find([1, 3]); p != none; p = ix.next[p]) n++;
    assert(n == 2);
    assert(ix.find([2, 3]) == none);
}
