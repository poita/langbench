module number_test;

import jsonschema.number;

private Number n(string s)
{
    return Number.fromLiteral(s);
}

unittest // equal values in different spellings
{
    assert(n("1") == n("1.0"));
    assert(n("1") == n("1.00"));
    assert(n("1") == n("1e0"));
    assert(n("100") == n("1e2"));
    assert(n("-0") == n("0"));
    assert(n("0.5") == n("5e-1"));
    assert(n("1") != n("2"));
}

unittest // integer test
{
    assert(n("1.0").isInteger);
    assert(n("1e2").isInteger);
    assert(n("-0").isInteger);
    assert(!n("1.5").isInteger);
    assert(!n("1e-1").isInteger);
}

unittest // ordering is exact
{
    assert(compare(n("1e309"), n("1e308")) > 0);
    assert(compare(n("-1"), n("1")) < 0);
    assert(compare(n("0.1"), n("0.10000000000000001")) < 0);
    assert(compare(n("0"), n("-0.0")) == 0);
    assert(compare(n("123456789012345678901234567890"), n("123456789012345678901234567891")) < 0);
    assert(compare(n("-5"), n("-6")) > 0);
    assert(compare(n("12.5"), n("125e-1")) == 0);
}

unittest // multipleOf is exact
{
    assert(isMultipleOf(n("0.3"), n("0.0001")));
    assert(isMultipleOf(n("0.0021"), n("0.0001")));
    assert(isMultipleOf(n("0"), n("7")));
    assert(isMultipleOf(n("10"), n("5")));
    assert(!isMultipleOf(n("7"), n("2")));
    assert(!isMultipleOf(n("1.5"), n("1")));
    assert(isMultipleOf(n("4.5"), n("1.5")));
    assert(isMultipleOf(n("1e308"), n("0.5")));
    assert(!isMultipleOf(n("0.00001"), n("0.0001")));
    assert(isMultipleOf(n("123456789012345678901234567890"), n("10")));
    assert(isMultipleOf(n("-6"), n("3")));
}

unittest // counts
{
    assert(n("2").toCount == 2);
    assert(n("2.0").toCount == 2);
    assert(n("2e0").toCount == 2);
    assert(n("1e30").toCount == long.max);
    assert(n("-1").toCount == -1);
    assert(n("0.5").toCount == 0);
}

unittest // equal numbers hash equally
{
    assert(n("1.0").toHash == n("1e0").toHash);
    assert(n("1" ~ "0".repeatStr(30)).toHash == n("1e30").toHash);
}

private string repeatStr(string s, size_t k)
{
    string r;
    foreach (i; 0 .. k)
        r ~= s;
    return r;
}
