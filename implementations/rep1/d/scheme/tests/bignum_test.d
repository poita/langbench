/// Unit tests for scheme.bignum.
module bignum_test;

import scheme.bignum;

private BigInt big(string s)
{
    bool neg = s[0] == '-';
    return BigInt.parseDecimal(neg ? s[1 .. $] : s, neg);
}

unittest // parse and print round trip
{
    foreach (s; ["0", "1", "123456789", "1000000000", "-1000000000",
            "4294967296", "18446744073709551616",
            "-123456789012345678901234567890123456789",
            "100000000000000000000000000000000000000"])
        assert(big(s).toDecimal() == s, s);
    assert(big("000123").toDecimal() == "123");
    assert(big("-0").toDecimal() == "0");
}

unittest // conversion to and from long
{
    foreach (v; [0L, 1, -1, 42, int.max, long.max, long.min, long.min + 1])
    {
        long r;
        assert(BigInt.fromLong(v).toLong(r));
        assert(r == v);
    }
    long r;
    assert(!big("9223372036854775808").toLong(r));
    assert(big("-9223372036854775808").toLong(r) && r == long.min);
    assert(!big("-9223372036854775809").toLong(r));
    assert(BigInt.fromLong(long.min).toDecimal() == "-9223372036854775808");
}

unittest // addition and subtraction
{
    assert(BigInt.add(big("4294967295"), big("1")).toDecimal() == "4294967296");
    assert(BigInt.add(big("-5"), big("5")).isZero);
    assert(BigInt.add(big("-5"), big("3")).toDecimal() == "-2");
    assert(BigInt.sub(big("1"), big("4294967296")).toDecimal() == "-4294967295");
    assert(BigInt.sub(big("100000000000000000000"), big("1")).toDecimal()
            == "99999999999999999999");
    assert(BigInt.sub(big("0"), big("7")).toDecimal() == "-7");
    assert(!BigInt.sub(big("7"), big("7")).neg);
}

unittest // multiplication
{
    assert(BigInt.mul(big("4294967296"), big("4294967296")).toDecimal()
            == "18446744073709551616");
    assert(BigInt.mul(big("-3"), big("4")).toDecimal() == "-12");
    assert(BigInt.mul(big("-3"), big("0")).toDecimal() == "0");
    assert(BigInt.mul(big("123456789012345678901234567890"),
            big("987654321098765432109876543210")).toDecimal()
            == "121932631137021795226185032733622923332237463801111263526900");
}

unittest // comparison
{
    assert(BigInt.compare(big("1"), big("2")) < 0);
    assert(BigInt.compare(big("-1"), big("-2")) > 0);
    assert(BigInt.compare(big("-1"), big("1")) < 0);
    assert(BigInt.compare(big("100000000000"), big("100000000000")) == 0);
    assert(BigInt.compare(big("100000000000"), big("99999999999")) > 0);
}

private void checkDiv(string a, string b, string q, string r)
{
    BigInt qq, rr;
    BigInt.divMod(big(a), big(b), qq, rr);
    assert(qq.toDecimal() == q, a ~ " / " ~ b ~ " quotient " ~ qq.toDecimal());
    assert(rr.toDecimal() == r, a ~ " / " ~ b ~ " remainder " ~ rr.toDecimal());
}

unittest // division, short and long divisors
{
    checkDiv("7", "2", "3", "1");
    checkDiv("-7", "2", "-3", "-1");
    checkDiv("7", "-2", "-3", "1");
    checkDiv("-7", "-2", "3", "-1");
    checkDiv("1", "5", "0", "1");
    checkDiv("100000000000000000000", "10", "10000000000000000000", "0");
    checkDiv("18446744073709551616", "4294967296", "4294967296", "0");
    checkDiv("121932631137021795226185032733622923332237463801111263526900",
            "987654321098765432109876543210", "123456789012345678901234567890", "0");
    checkDiv("121932631137021795226185032733622923332237463801111263526907",
            "987654321098765432109876543210", "123456789012345678901234567890", "7");
    checkDiv("340282366920938463463374607431768211455", "18446744073709551615",
            "18446744073709551617", "0");
}

unittest // division identity on a spread of values
{
    string[] xs = ["1", "4294967295", "4294967296", "18446744073709551615",
        "79228162514264337593543950336", "340282366920938463463374607431768211457",
        "99999999999999999999999999999999999999999999"];
    foreach (a; xs)
        foreach (b; xs)
            foreach (sa; ["", "-"])
            {
                auto x = big(sa ~ a);
                auto y = big(b);
                BigInt q, r;
                BigInt.divMod(x, y, q, r);
                auto back = BigInt.add(BigInt.mul(q, y), r);
                assert(BigInt.compare(back, x) == 0);
                assert(BigInt.compare(BigInt.fromLong(0), r) == 0
                        || r.neg == x.neg);
            }
}

unittest // factorial of 30
{
    BigInt acc = BigInt.fromLong(1);
    foreach (i; 1 .. 31)
        acc = BigInt.mul(acc, BigInt.fromLong(i));
    assert(acc.toDecimal() == "265252859812191058636308480000000");
}
