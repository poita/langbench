/// Tests for run-time value helpers: lists, maps, equality.
module langvm.test_value;

import langvm.value;

unittest
{
    auto l = new ListObj;
    foreach (i; 0 .. 100)
        l.push(Value.int_(i));
    assert(l.len == 100 && l.buf[99].i == 99);
    assert(l.pop().i == 99);
    l.insertAt(0, Value.int_(-1));
    assert(l.buf[0].i == -1 && l.buf[1].i == 0 && l.len == 100);
    assert(l.removeAt(0).i == -1);
    assert(l.buf[0].i == 0);
}

unittest
{
    auto m = new MapObj;
    foreach (i; 0 .. 1000)
        m.set(Value.int_(i), Value.int_(i * 2));
    assert(m.count == 1000);
    assert(m.vals[m.find(Value.int_(500))].i == 1000);
    foreach (i; 0 .. 1000)
        if (i % 2)
            assert(m.remove(Value.int_(i)));
    assert(m.count == 500 && m.find(Value.int_(3)) < 0);
    // insertion order survives deletion and compaction
    long prev = -1;
    foreach (i; 0 .. m.used)
    {
        if (m.keys[i].t == VT.unit)
            continue;
        assert(m.keys[i].i > prev);
        prev = m.keys[i].i;
    }
    m.set(Value.int_(0), Value.int_(7));
    assert(m.keys[0].i == 0 && m.vals[0].i == 7);
    m.remove(Value.int_(0));
    m.set(Value.int_(0), Value.int_(1));
    assert(m.keys[m.used - 1].i == 0);
}

unittest
{
    auto a = Value.str("héllo"d);
    auto b = Value.str("héllo"d);
    assert(valuesEqual(a, b));
    assert(!valuesEqual(a, Value.str("hello"d)));
    assert(compareStr("ab"d, "abc"d) == -1 && compareStr("b"d, "ab"d) == 1);
    auto m = new MapObj;
    m.set(a, Value.int_(1));
    assert(m.find(b) == 0);
    assert(!valuesEqual(Value.float_(double.nan), Value.float_(double.nan)));
    assert(valuesEqual(Value.float_(-0.0), Value.float_(0.0)));
}
