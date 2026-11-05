/// Unit tests for BigInt arithmetic, parsing and printing.
module tests.test_arith;

import std.exception : assertThrown;
import bigint;

private BigInt B(string s) { return BigInt(s); }

unittest // parsing and canonical printing
{
    assert(B("0").toString() == "0");
    assert(B("-0").toString() == "0");
    assert(B("-000").toString() == "0");
    assert(B("007").toString() == "7");
    assert(B("-000123").toString() == "-123");
    assert(B("1000000000").toString() == "1000000000");
    assert(B("999999999").toString() == "999999999");
    assert(B("1000000000000000000").toString() == "1000000000000000000");
    assert(B("-0").sign == 0 && !B("-0").isNegative);
    assert(BigInt(-5).toString() == "-5");
    assert(BigInt(long.min).toString() == "-9223372036854775808");
    assert(BigInt(0).isZero);
    assertThrown!Exception(BigInt(""));
    assertThrown!Exception(BigInt("-"));
    assertThrown!Exception(BigInt("12a4"));
}

unittest // addition and subtraction
{
    assert((B("12") + B("30")).toString() == "42");
    assert((B("5") - B("7")).toString() == "-2");
    assert((B("99999999999999999999") + B("1")).toString() == "100000000000000000000");
    assert((B("1000000000000000000000000000000") - B("1")).toString()
            == "999999999999999999999999999999");
    assert((B("-5") + B("5")).toString() == "0");
    assert(!(B("-5") + B("5")).isNegative);
    assert((B("-0") + B("0")).toString() == "0");
    assert((B("-3") - B("-8")).toString() == "5");
    assert((B("-3") - B("8")).toString() == "-11");
    assert((B("100000000000000000000") - B("100000000000000000000")).isZero);
    assert((-B("5")).toString() == "-5");
    assert((-B("0")).toString() == "0");
}

unittest // multiplication
{
    assert((B("-123456789012345678901234567890") * B("987654321098765432109876543210"))
            .toString() == "-121932631137021795226185032733622923332237463801111263526900");
    assert((B("-5") * B("0")).toString() == "0");
    assert(!(B("-5") * B("0")).isNegative);
    assert((B("999999999") * B("999999999")).toString() == "999999998000000001");
    // Zero limbs in the multiplier are skipped correctly.
    assert((B("1000000000000000000000000001") * B("1000000000000000000000000001")).toString()
            == "1000000000000000000000000002000000000000000000000000001");
}

unittest // division and remainder (C semantics)
{
    void check(string a, string b, string q, string r)
    {
        BigInt qq, rr;
        divMod(B(a), B(b), qq, rr);
        assert(qq.toString() == q, a ~ " / " ~ b);
        assert(rr.toString() == r, a ~ " % " ~ b);
        assert((B(a) / B(b)).toString() == q);
        assert((B(a) % B(b)).toString() == r);
    }
    check("7", "2", "3", "1");
    check("-7", "2", "-3", "-1");
    check("7", "-2", "-3", "1");
    check("-7", "-2", "3", "-1");
    check("-1", "3", "0", "-1");
    check("-1", "2", "0", "-1");
    check("-7", "7", "-1", "0");
    check("0", "5", "0", "0");
    check("1000000000000000000000", "1000000000", "1000000000000", "0");
    // Multi-limb divisor, including the rare add-back correction patterns.
    check("100000000000000000000000000000000000000", "99999999999999999999",
            "1000000000000000000", "1000000000000000000");
    assertThrown!BigIntException(B("1") / B("0"));
    assertThrown!BigIntException(B("0") % B("-0"));
}

unittest // exponentiation
{
    assert((B("2") ^^ 10).toString() == "1024");
    assert((B("0") ^^ 0).toString() == "1");
    assert((B("0") ^^ 5).toString() == "0");
    assert((B("-2") ^^ 3).toString() == "-8");
    assert((B("-2") ^^ 2).toString() == "4");
    assert((B("-1") ^^ 999).toString() == "-1");
    assert((B("1") ^^ 123456).toString() == "1");
    assert((B("-7") ^^ 0).toString() == "1");
    assert(pow(B("2"), 100).toString() == "1267650600228229401496703205376");
    assert(pow(B("10"), 50).toString() == "1" ~ "00000000000000000000000000000000000000000000000000");
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
    assert(B("5").opCmp(B("5")) == 0);
}

unittest // conversions and helpers
{
    assert(B("5000").toUlong() == 5000);
    assert(B("0").toUlong() == 0);
    assert(B("18446744073709551615").toUlong() == ulong.max);
    assertThrown!BigIntException(B("18446744073709551616").toUlong());
    assertThrown!BigIntException(B("-1").toUlong());
    assert(B("3").isOdd && !B("4").isOdd && !B("0").isOdd);
    assert(B("-3").abs == B("3"));
}

unittest // writeTo with an Appender
{
    import std.array : appender;
    auto app = appender!(char[])();
    B("-1234567890123").writeTo(app);
    assert(app.data == "-1234567890123");
}
