/// Unit tests for bigint.integer (the signed BigInt type).
module integer_test;

import bigint.integer;
import std.exception : assertThrown;
import std.format : format;

private BigInt B(string s) { return BigInt(s); }

unittest // construction and canonical form
{
    assert(B("0").toString == "0");
    assert(B("-0").toString == "0");
    assert(B("-000").toString == "0");
    assert(!B("-0").isNegative);
    assert(B("007").toString == "7");
    assert(B("-000123").toString == "-123");
    assert(BigInt(long.min).toString == "-9223372036854775808");
    assert(BigInt(long.max).toString == "9223372036854775807");
    assert(BigInt(0) == B("-0"));
    assertThrown!BigIntException(BigInt("12x"));
    assertThrown!BigIntException(BigInt(""));
    assertThrown!BigIntException(BigInt("-"));
}

unittest // toLong
{
    long v;
    assert(B("123").toLong(v) && v == 123);
    assert(B("-9223372036854775808").toLong(v) && v == long.min);
    assert(!B("9223372036854775808").toLong(v));
    assert(!B("100000000000000000000000").toLong(v));
}

unittest // add and subtract sign handling
{
    assert((B("12") + B("30")).toString == "42");
    assert((B("5") - B("7")).toString == "-2");
    assert((B("-5") - B("-7")).toString == "2");
    assert((B("-5") + B("5")).toString == "0");
    assert(!(B("-5") + B("5")).isNegative);
    assert((B("-0") + B("0")).toString == "0");
    assert((B("99999999999999999999") + B("1")).toString == "100000000000000000000");
    assert((B("1000000000000000000000000000000") - B("1")).toString
        == "999999999999999999999999999999");
    assert((-B("5")).toString == "-5");
    assert((-B("0")).toString == "0");
}

unittest // multiplication
{
    assert((B("-123456789012345678901234567890") * B("987654321098765432109876543210")).toString
        == "-121932631137021795226185032733622923332237463801111263526900");
    assert((B("-5") * B("0")).toString == "0");
    assert(!(B("-5") * B("0")).isNegative);
}

unittest // division semantics: truncation toward zero, remainder sign of dividend
{
    static struct C { string a, b, q, r; }
    immutable C[] cases = [
        C("7", "2", "3", "1"), C("-7", "2", "-3", "-1"),
        C("7", "-2", "-3", "1"), C("-7", "-2", "3", "-1"),
        C("-1", "3", "0", "-1"), C("-1", "2", "0", "-1"),
        C("-7", "7", "-1", "0"), C("0", "5", "0", "0"),
    ];
    foreach (c; cases)
    {
        auto qr = divMod(B(c.a), B(c.b));
        assert(qr.quotient.toString == c.q, c.a ~ " / " ~ c.b);
        assert(qr.remainder.toString == c.r, c.a ~ " % " ~ c.b);
        assert((B(c.a) / B(c.b)).toString == c.q);
        assert((B(c.a) % B(c.b)).toString == c.r);
        assert(!qr.quotient.isNegative || !qr.quotient.isZero);
    }
    assertThrown!BigIntException(B("1") / B("0"));
    assertThrown!BigIntException(B("0") % B("-0"));
}

unittest // big division
{
    auto a = B("123456789012345678901234567890123456789012345678901234567890");
    auto b = B("98765432109876543210987654321");
    auto qr = divMod(a, b);
    assert(qr.quotient * b + qr.remainder == a);
    assert(qr.remainder < b);
}

unittest // exponentiation
{
    assert(pow(B("2"), 10).toString == "1024");
    assert(pow(B("0"), 0).toString == "1");
    assert(pow(B("0"), 5).toString == "0");
    assert(pow(B("-2"), 3).toString == "-8");
    assert(pow(B("-2"), 2).toString == "4");
    assert(pow(B("-1"), 999).toString == "-1");
    assert(pow(B("-1"), 1000).toString == "1");
    assert(pow(B("7"), 0).toString == "1");
    assert((B("3") ^^ 40).toString == "12157665459056928801");
    assert(pow(B("10"), 100).toString.length == 101);
}

unittest // comparison
{
    assert(B("-3") < B("-2"));
    assert(B("007") == B("7"));
    assert(B("-0") == B("0"));
    assert(B("10") > B("9"));
    assert(B("-10") < B("9"));
    assert(B("1000000000") > B("999999999"));
    assert(B("-1000000000") < B("-999999999"));
}

unittest // formatting
{
    assert(format("%s", B("-42")) == "-42");
}
