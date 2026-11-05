module tests.value_test;

import jq;

unittest // value constructors and predicates
{
    assert(mkNull().isNull && !mkNull().truthy);
    assert(!mkBool(false).truthy && mkBool(true).truthy);
    assert(mkNum(0).truthy);
    assert(mkStr("").truthy && mkStr("héllo").str == "héllo");
    assert(mkArr([mkNum(1), mkNum(2)]).arr.length == 2);
    assert(Value.sizeof == 16);
}

unittest // Obj keeps insertion order, replaces in place
{
    auto o = new Obj;
    o.set("b", mkNum(1));
    o.set("a", mkNum(2));
    o.set("b", mkNum(3));
    assert(o.length == 2);
    assert(o.entries[0].key == "b" && o.entries[0].val.num == 3);
    assert(toJson(mkObj(o)) == `{"b":3,"a":2}`);
}

unittest // sorted key order
{
    auto o = new Obj;
    foreach (k; ["z", "é", "a", "Z", "ab"])
        o.set(k, mkNull());
    string[] got;
    foreach (p; o.sortedOrder())
        got ~= o.entries[p].key;
    assert(got == ["Z", "a", "ab", "z", "é"]);
}

unittest // copyOf does not alias
{
    auto a = new Obj;
    a.set("x", mkNum(1));
    auto b = Obj.copyOf(a, 1);
    b.set("y", mkNum(2));
    b.set("x", mkNum(9));
    assert(a.length == 1 && a.entries[0].val.num == 1);
    assert(b.length == 2);
}

unittest // many keys: hash index stays consistent while growing
{
    auto o = new Obj;
    foreach (i; 0 .. 1000)
    {
        import std.conv : to;
        o.set("key" ~ i.to!string, mkNum(i));
    }
    foreach (i; 0 .. 1000)
    {
        import std.conv : to;
        bool f;
        assert(o.get("key" ~ i.to!string, f).num == i && f);
    }
    assert(o.length == 1000);
}

unittest // total order
{
    auto order = [
        `null`, `false`, `true`, `-1`, `0`, `1.5`, `""`, `"a"`, `"ab"`, `"b"`, `[]`,
        `[0]`, `[0,1]`, `[1]`, `{}`, `{"a":1}`, `{"a":2}`, `{"a":1,"b":0}`, `{"b":0}`,
    ];
    foreach (i, x; order)
        foreach (j, y; order)
        {
            immutable c = compare(parseJson(x), parseJson(y));
            assert((c < 0) == (i < j) && (c == 0) == (i == j), x ~ " vs " ~ y);
        }
    assert(equals(parseJson(`{"a":1,"b":2}`), parseJson(`{"b":2,"a":1}`)));
    assert(equals(parseJson("1"), parseJson("1.0")));
}
