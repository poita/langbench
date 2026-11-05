module tests.test_value;

import jq;
import tests.helpers;

private Value J(string s) { return parseJson(s); }

unittest // type order
{
    auto order = [`null`, `false`, `true`, `0`, `"a"`, `[]`, `{}`];
    foreach (i; 0 .. order.length)
        foreach (j; 0 .. order.length)
            assert((compare(J(order[i]), J(order[j])) < 0) == (i < j), order[i] ~ " vs " ~ order[j]);
}

unittest // within-type ordering
{
    assert(compare(J(`1`), J(`2.5`)) < 0);
    assert(compare(J(`"Z"`), J(`"a"`)) < 0);
    assert(compare(J(`"z"`), J(`"é"`)) < 0);
    assert(compare(J(`"ab"`), J(`"b"`)) < 0);
    assert(compare(J(`[1]`), J(`[1,0]`)) < 0);
    assert(compare(J(`[[1]]`), J(`[[0,9]]`)) > 0);
}

unittest // object ordering: sorted key lists first, then values
{
    assert(compare(J(`{"a":2}`), J(`{"b":1}`)) < 0);
    assert(compare(J(`{"a":1,"b":1}`), J(`{"a":1}`)) > 0);
    assert(compare(J(`{"a":1}`), J(`{"a":2}`)) < 0);
    assert(equals(J(`{"a":1,"b":2}`), J(`{"b":2,"a":1}`)));
}

unittest // truthiness
{
    assert(!J(`null`).truthy);
    assert(!J(`false`).truthy);
    foreach (s; [`0`, `""`, `[]`, `{}`, `true`])
        assert(J(s).truthy);
}

unittest // object builder keeps first position, last value
{
    auto o = new JObj();
    o.set(new JStr("a"), Value.makeNumber(1));
    o.set(new JStr("b"), Value.makeNumber(2));
    o.set(new JStr("a"), Value.makeNumber(3));
    assert(toJson(Value.makeObject(o)) == `{"a":3,"b":2}`);
}

unittest // large objects use the hash index
{
    auto o = new JObj();
    foreach (i; 0 .. 100)
        o.set(new JStr(toJson(Value.makeNumber(i))), Value.makeNumber(i));
    assert(o.length == 100);
    assert(o.get("57").num == 57);
    assert(!o.has("100"));
    o.set(new JStr("57"), Value.makeNumber(-1));
    assert(o.length == 100 && o.get("57").num == -1);
}
