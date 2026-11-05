module tests.test_semver_range;

import depresolve.range;
import depresolve.semver;

private Interval iv(string s) { return parseRange(s); }
private VersionKey v(ulong a, ulong b, ulong c) { return packVersion(a, b, c); }

unittest // numeric ordering of packed keys
{
    assert(v(1, 10, 0) > v(1, 9, 0));
    assert(v(2, 0, 0) > v(1, 999_999, 999_999));
    assert(v(0, 0, 1) > v(0, 0, 0));
}

unittest // parse and format round trip
{
    const(char)[] s = "12.345.6789 rest";
    const k = parseVersion(s);
    assert(k == v(12, 345, 6789));
    assert(s == " rest");
    assert(formatVersion(k) == "12.345.6789");
    assert(formatVersion(v(1_000_000, 0, 1_000_000)) == "1000000.0.1000000");
}

unittest // wildcard and exact
{
    assert(iv("*").contains(v(0, 0, 0)));
    assert(iv("*").contains(v(1_000_000, 1_000_000, 1_000_000)));
    const e = iv("1.2.3");
    assert(e.contains(v(1, 2, 3)));
    assert(!e.contains(v(1, 2, 4)) && !e.contains(v(1, 2, 2)));
}

unittest // caret
{
    auto a = iv("^1.2.3");
    assert(a.contains(v(1, 2, 3)) && a.contains(v(1, 99, 0)) && !a.contains(v(2, 0, 0)) && !a.contains(v(1, 2, 2)));
    auto b = iv("^0.2.3");
    assert(b.contains(v(0, 2, 9)) && !b.contains(v(0, 3, 0)) && !b.contains(v(0, 2, 2)));
    auto c = iv("^0.0.3");
    assert(c.contains(v(0, 0, 3)) && !c.contains(v(0, 0, 4)) && !c.contains(v(0, 0, 2)));
}

unittest // tilde
{
    auto a = iv("~1.2.3");
    assert(a.contains(v(1, 2, 3)) && a.contains(v(1, 2, 50)) && !a.contains(v(1, 3, 0)));
    auto b = iv("~0.0.3");
    assert(b.contains(v(0, 0, 3)) && b.contains(v(0, 0, 9)) && !b.contains(v(0, 1, 0)));
}

unittest // comparators
{
    auto a = iv(">=1.0.0 <2.0.0");
    assert(a.contains(v(1, 0, 0)) && a.contains(v(1, 9, 9)) && !a.contains(v(2, 0, 0)) && !a.contains(v(0, 9, 9)));
    auto b = iv(">1.0.0 <=1.0.5");
    assert(!b.contains(v(1, 0, 0)) && b.contains(v(1, 0, 1)) && b.contains(v(1, 0, 5)) && !b.contains(v(1, 0, 6)));
    assert(iv(">=2.0.0 <1.0.0").empty);
    assert(iv(">=1.0.0 <=2.0.0 >1.5.0").contains(v(2, 0, 0)));
    assert(!iv(">=1.0.0 <=2.0.0 >1.5.0").contains(v(1, 5, 0)));
}

unittest // bounds at the component limit
{
    assert(iv("^1000000.0.0").contains(v(1_000_000, 5, 5)));
    assert(iv("~0.1000000.0").contains(v(0, 1_000_000, 7)));
    assert(iv("<=1000000.1000000.1000000").contains(v(1_000_000, 1_000_000, 1_000_000)));
    assert(!iv(">1000000.1000000.1000000").contains(v(1_000_000, 1_000_000, 1_000_000)));
}
