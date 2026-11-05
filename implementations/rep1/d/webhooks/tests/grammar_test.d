module grammar_test;

import webhooks.grammar;

private const(ubyte)[] b(string s) { return cast(const(ubyte)[]) s; }

@("grammar: canonical integers")
unittest
{
    long v;
    assert(parseInt(b("0"), v) && v == 0);
    assert(parseInt(b("-5"), v) && v == -5);
    assert(parseInt(b("1000000000000000"), v) && v == 1_000_000_000_000_000);
    assert(parseInt(b("-1000000000000000"), v));
    foreach (bad; ["", "-", "-0", "+5", "007", "1.0", "1e3", "1000000000000001", "12345678901234567890", " 1"])
        assert(!parseInt(b(bad), v), bad);
}

@("grammar: split fields keeps empties")
unittest
{
    auto f = splitFields(b("a  b"));
    assert(f.count == 3 && f.anyEmpty);
    f = splitFields(b("a b "));
    assert(f.count == 3 && f.anyEmpty);
    f = splitFields(b("a b"));
    assert(f.count == 2 && !f.anyEmpty && equals(f[1], "b"));
}

@("grammar: id and name validation")
unittest
{
    assert(isId(b("-")));
    assert(!isId(b("")));
    assert(!isId(b("a b")));
    assert(isName(b("ep_1.x-y")));
    assert(!isName(b("a,b")));
    assert(!isName(b("")));
}

@("grammar: line reader handles missing final newline")
unittest
{
    auto r = LineReader(b("a\n\nb"));
    assert(equals(r.next(), "a"));
    assert(equals(r.next(), ""));
    assert(equals(r.next(), "b"));
    assert(r.empty);
}
