module tests.idmap_test;

import std.conv : to;
import orderbook.idmap;

unittest // basic put/get/remove
{
    auto m = IdMap(4);
    assert(m.get("a") == -1 && m.length == 0);
    m.put("a", 0);
    m.put("BUY", 1);
    m.put("a", 5); // overwrite
    assert(m.get("a") == 5 && m.get("BUY") == 1 && m.length == 2);
    assert(m.remove("a") && !m.remove("a"));
    assert(m.get("a") == -1 && m.get("BUY") == 1);
}

unittest // growth and deletion keep every other key reachable
{
    auto m = IdMap(0);
    string[] keys;
    foreach (i; 0 .. 5000)
        keys ~= "id" ~ i.to!string;
    foreach (i, k; keys)
        m.put(k, cast(int) i);
    assert(m.length == 5000);
    foreach (i, k; keys)
        if (i % 3 == 0)
            assert(m.remove(k));
    foreach (i, k; keys)
        assert(m.get(k) == (i % 3 == 0 ? -1 : cast(int) i));
    assert(m.length == 5000 - 1667);
}

unittest // lookups use borrowed slices of a larger buffer
{
    string buf = "xxabcxx";
    auto m = IdMap(4);
    m.put(buf[2 .. 5], 3);
    assert(m.get("abc") == 3);
}
