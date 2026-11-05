/// Unit tests for depresolve.semver and depresolve.range.
module test_semver_range;

import std.exception : assertThrown;
import depresolve.range;
import depresolve.semver;

@safe pure unittest // numeric ordering
{
    assert(parseVersion("1.10.0") > parseVersion("1.9.0"));
    assert(parseVersion("2.0.0") > parseVersion("1.999999.999999"));
    assert(parseVersion("0.0.0") < parseVersion("0.0.1"));
    assert(parseVersion("1000000.1000000.1000000").toString == "1000000.1000000.1000000");
}

@safe pure unittest // components
{
    const v = parseVersion("3.14.159");
    assert(v.major == 3 && v.minor == 14 && v.patch == 159);
}

@safe pure unittest // caret
{
    assert(parseRange("^1.2.3").contains(parseVersion("1.9.9")));
    assert(!parseRange("^1.2.3").contains(parseVersion("2.0.0")));
    assert(!parseRange("^1.2.3").contains(parseVersion("1.2.2")));
    assert(parseRange("^0.2.3").contains(parseVersion("0.2.9")));
    assert(!parseRange("^0.2.3").contains(parseVersion("0.3.0")));
    assert(parseRange("^0.0.3").contains(parseVersion("0.0.3")));
    assert(!parseRange("^0.0.3").contains(parseVersion("0.0.4")));
    assert(!parseRange("^0.0.0").contains(parseVersion("0.0.1")));
    assert(parseRange("^0.0.0").contains(parseVersion("0.0.0")));
}

@safe pure unittest // tilde
{
    assert(parseRange("~1.2.3").contains(parseVersion("1.2.99")));
    assert(!parseRange("~1.2.3").contains(parseVersion("1.3.0")));
    assert(parseRange("~0.0.3").contains(parseVersion("0.0.9")));
    assert(!parseRange("~0.0.3").contains(parseVersion("0.1.0")));
}

@safe pure unittest // wildcard and exact
{
    assert(parseRange("*").contains(parseVersion("0.0.0")));
    assert(parseRange("1.2.3").contains(parseVersion("1.2.3")));
    assert(!parseRange("1.2.3").contains(parseVersion("1.2.4")));
}

@safe pure unittest // comparators
{
    auto r = parseRange(">=1.0.0 <2.0.0");
    assert(r.contains(parseVersion("1.0.0")) && r.contains(parseVersion("1.99.0")));
    assert(!r.contains(parseVersion("2.0.0")) && !r.contains(parseVersion("0.9.9")));
    assert(!parseRange(">1.0.0").contains(parseVersion("1.0.0")));
    assert(parseRange(">1.0.0").contains(parseVersion("1.0.1")));
    assert(parseRange("<=1.0.0").contains(parseVersion("1.0.0")));
    assert(!parseRange("<1.0.0").contains(parseVersion("1.0.0")));
    assert(parseRange(">=2.0.0 <1.0.0").empty);
    assert(parseRange(">1.0.0 >=1.5.0 <=1.6.0").contains(parseVersion("1.6.0")));
}

@safe pure unittest // parse position stops at a comma
{
    size_t pos = 0;
    const s = ">=1.0.0 <2.0.0, b *";
    parseRange(s, pos);
    assert(s[pos .. $] == ", b *");
}

@safe unittest // malformed input
{
    assertThrown!ParseException(parseVersion("1.2"));
    assertThrown!ParseException(parseVersion("1.2.3x"));
    assertThrown!ParseException(parseRange("?1.0.0"));
    assertThrown!ParseException(parseRange("^"));
}
