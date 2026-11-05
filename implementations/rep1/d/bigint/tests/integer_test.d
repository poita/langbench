/// Unit tests for bigint.integer.BigInt.
module integer_test;

import std.exception : assertThrown;
import bigint.integer;

unittest // construction and canonical text
{
    assert(BigInt("-0").toString == "0");
    assert(BigInt("-000").isZero && !BigInt("-000").isNegative);
    assert(BigInt("007").toString == "7");
    assert(BigInt("-000123").toString == "-123");
    assert(BigInt(-1234567890123L).toString == "-1234567890123");
    assert(BigInt(long.min).toString == "-9223372036854775808");
    assertThrown(BigInt("12a"));
    assertThrown(BigInt("-"));
}

unittest // comparison
{
    assert(BigInt("-3") < BigInt("-2"));
    assert(BigInt("-0") == BigInt("0"));
    assert(BigInt("007") == BigInt("7"));
    assert(BigInt("10") > BigInt("-100"));
    assert(BigInt("100000000000") > BigInt("99999999999"));
    assert(BigInt("-100000000000") < BigInt("-99999999999"));
}

unittest // add / sub / mul
{
    assert(BigInt("12") + BigInt("30") == BigInt("42"));
    assert(BigInt("5") - BigInt("7") == BigInt("-2"));
    assert((BigInt("-0") + BigInt("0")).toString == "0");
    assert((BigInt("-5") * BigInt("0")).toString == "0");
    assert((BigInt("7") - BigInt("7")).toString == "0");
    assert((BigInt("99999999999999999999") + BigInt(1)).toString == "100000000000000000000");
    assert((-BigInt("5")).toString == "-5");
    assert((-BigInt("0")).toString == "0");
    auto x = BigInt("1");
    x += BigInt("2");
    x *= BigInt("-5");
    assert(x.toString == "-15");
}

unittest // division semantics
{
    static void check(string a, string b, string q, string r)
    {
        assert((BigInt(a) / BigInt(b)).toString == q, a ~ " / " ~ b);
        assert((BigInt(a) % BigInt(b)).toString == r, a ~ " % " ~ b);
    }

    check("7", "2", "3", "1");
    check("-7", "2", "-3", "-1");
    check("7", "-2", "-3", "1");
    check("-7", "-2", "3", "-1");
    check("-1", "3", "0", "-1");
    check("-7", "7", "-1", "0");
    check("-1", "2", "0", "-1");
    assertThrown(BigInt("1") / BigInt("0"));
    assertThrown(BigInt("0") % BigInt("-0"));
}

unittest // pow
{
    assert(pow(BigInt("-2"), BigInt("3")).toString == "-8");
    assert(pow(BigInt("-2"), BigInt("2")).toString == "4");
    assert(pow(BigInt("-1"), BigInt("999")).toString == "-1");
    assert(pow(BigInt("0"), BigInt("0")).toString == "1");
    assert(pow(BigInt("0"), BigInt("5")).toString == "0");
    assert(pow(BigInt("5"), BigInt("-0")).toString == "1");
    assert(pow(BigInt("-0"), BigInt("-00")).toString == "1");
    assertThrown(pow(BigInt("2"), BigInt("-1")));
    assert((BigInt(2) ^^ BigInt(64)).toString == "18446744073709551616");
}
