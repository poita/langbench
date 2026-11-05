module test_value;

import jq;

unittest // type order
{
    auto order = [
        Value.nullValue, Value.boolean(false), Value.boolean(true), Value.number(-1), Value.number(2),
        Value.string_("a"), Value.array([Value.number(1)]), Value.object(new JObject)
    ];
    foreach (i; 0 .. order.length)
        foreach (j; 0 .. order.length)
            assert(compare(order[i], order[j]) == (i < j ? -1 : (i > j ? 1 : 0)));
}

unittest // strings compare by bytes
{
    assert(compare(Value.string_(""), Value.string_("a")) < 0);
    assert(compare(Value.string_("a"), Value.string_("ab")) < 0);
    assert(compare(Value.string_("Z"), Value.string_("a")) < 0);
    assert(compare(Value.string_("z"), Value.string_("é")) < 0);
}

unittest // arrays compare lexicographically
{
    auto a = Value.array([Value.number(1), Value.number(2)]);
    auto b = Value.array([Value.number(1), Value.number(2), Value.number(0)]);
    auto c = Value.array([Value.number(1), Value.number(3)]);
    assert(compare(a, b) < 0);
    assert(compare(b, c) < 0);
    assert(compare(c, a) > 0);
}

unittest // objects: sorted keys first, then values; insertion order is irrelevant
{
    auto x = parseJson(`{"b":1,"a":2}`);
    auto y = parseJson(`{"a":2,"b":1}`);
    auto z = parseJson(`{"a":1,"c":0}`);
    auto w = parseJson(`{"a":3}`);
    assert(x == y);
    assert(compare(x, z) < 0); // keys [a,b] < [a,c]
    assert(compare(w, x) < 0); // [a] is a prefix of [a,b]
    assert(compare(parseJson(`{"a":1,"b":9}`), x) < 0); // same keys, a:1 < a:2
}

unittest // JObject keeps insertion order and replaces in place
{
    auto o = new JObject;
    o.set(new JStr("z"), Value.number(1));
    o.set(new JStr("a"), Value.number(2));
    o.set(new JStr("z"), Value.number(3));
    assert(o.length == 2);
    assert(o.entries[0].key.s == "z" && o.entries[0].val.num == 3);
    assert(o.entries[1].key.s == "a");
    bool found;
    o.get("a", found);
    assert(found);
    o.get("q", found);
    assert(!found);
}

unittest // hash index kicks in for large objects and survives copies
{
    auto o = new JObject;
    foreach (i; 0 .. 100)
        o.set(new JStr("key" ~ cast(char)('a' + i % 26) ~ cast(char)('a' + i / 26)), Value.number(i));
    assert(o.length == 100);
    bool found;
    assert(o.get("keyba", found).num == 1 && found);
    auto c = o.copy(1);
    c.set(new JStr("extra"), Value.number(-1));
    assert(c.length == 101 && o.length == 100);
    assert(!o.has(new JStr("extra")));
    assert(c.get("extra", found).num == -1 && found);
    assert(c.get("keyba", found).num == 1);
}

unittest // sorted key order is by code point and memoised
{
    auto o = parseJson(`{"é":1,"b":2,"Z":3,"a":4}`).obj;
    auto ord = o.sortedOrder;
    string[] keys;
    foreach (p; ord)
        keys ~= o.entries[p].key.s;
    assert(keys == ["Z", "a", "b", "é"]);
    assert(o.sortedOrder.ptr is ord.ptr);
}

unittest // truthiness
{
    assert(!Value.nullValue.truthy);
    assert(!Value.boolean(false).truthy);
    assert(Value.boolean(true).truthy);
    assert(Value.number(0).truthy);
    assert(Value.string_("").truthy);
}

unittest // code point helpers
{
    assert(codePointCount("héllo") == 5);
    assert(codePointCount("😀") == 1);
    assert(byteOffsetOfCodePoint("héllo", 2) == 3);
    assert(byteOffsetOfCodePoint("ab", 5) == 2);
}

unittest // stable ordering
{
    int[] keys = [2, 1, 2, 1, 0];
    auto order = stableOrder(keys.length, (a, b) => keys[a] - keys[b]);
    assert(order == [4, 1, 3, 0, 2]);
}
