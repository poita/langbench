module test_range;

import std.exception : assertThrown;
import depresolve.range;
import depresolve.semver;

private bool accepts(string range, string ver)
{
    return parseRange(range).contains(parseVersion(ver));
}

unittest // star and exact
{
    assert(accepts("*", "0.0.0"));
    assert(accepts("*", "1000000.1000000.1000000"));
    assert(accepts("1.2.3", "1.2.3"));
    assert(!accepts("1.2.3", "1.2.4"));
    assert(!accepts("1.2.3", "1.2.2"));
}

unittest // caret
{
    assert(accepts("^1.2.3", "1.2.3"));
    assert(accepts("^1.2.3", "1.9.0"));
    assert(!accepts("^1.2.3", "1.2.2"));
    assert(!accepts("^1.2.3", "2.0.0"));
    assert(accepts("^0.2.3", "0.2.9"));
    assert(!accepts("^0.2.3", "0.3.0"));
    assert(!accepts("^0.2.3", "0.2.2"));
    assert(accepts("^0.0.3", "0.0.3"));
    assert(!accepts("^0.0.3", "0.0.4"));
    assert(!accepts("^0.0.3", "0.0.2"));
    assert(accepts("^0.0.0", "0.0.0"));
    assert(!accepts("^0.0.0", "0.0.1"));
}

unittest // tilde
{
    assert(accepts("~1.2.3", "1.2.9"));
    assert(!accepts("~1.2.3", "1.3.0"));
    assert(!accepts("~1.2.3", "1.2.2"));
    assert(accepts("~0.0.3", "0.0.9"));
    assert(accepts("~0.0.3", "0.0.3"));
    assert(!accepts("~0.0.3", "0.1.0"));
}

unittest // comparators
{
    assert(accepts("<2.0.0", "1.9.9"));
    assert(!accepts("<2.0.0", "2.0.0"));
    assert(accepts("<=2.0.0", "2.0.0"));
    assert(!accepts("<=2.0.0", "2.0.1"));
    assert(accepts(">1.0.0", "1.0.1"));
    assert(!accepts(">1.0.0", "1.0.0"));
    assert(accepts(">=1.0.0", "1.0.0"));
    assert(!accepts(">=1.0.0", "0.9.9"));
    assert(accepts(">=1.2.0 <2.0.0", "1.5.0"));
    assert(!accepts(">=1.2.0 <2.0.0", "2.0.0"));
    assert(accepts(">1.0.0 >=1.5.0 <=1.5.0", "1.5.0"));
    assert(!accepts(">1.0.0 >=1.5.0 <=1.5.0", "1.4.9"));
}

unittest // empty-in-effect ranges
{
    assert(parseRange(">=2.0.0 <1.0.0").empty);
    assert(parseRange(">1.0.0 <1.0.1").empty);
    assert(parseRange("<0.0.0").empty);
    assert(!parseRange("*").empty);
}

unittest // interval helpers
{
    auto a = Interval(5, 10);
    assert(a.contains(5UL) && a.contains(9UL) && !a.contains(10UL) && !a.contains(4UL));
    assert(a.intersect(Interval(7, 20)) == Interval(7, 10));
    assert(a.intersect(Interval(10, 20)).empty);
}

unittest // malformed ranges
{
    foreach (bad; ["", "^", "~", "^1.2", "x", "**", "<", "<=", "<1.2", ">= 1.0.0",
                   "=1.0.0", "<1.0.0  >2.0.0", "<1.0.0 ", "^ 1.0.0", "1.x"])
        assertThrown!ParseException(parseRange(bad), bad);
}
