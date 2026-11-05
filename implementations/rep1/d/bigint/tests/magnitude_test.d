/// Unit tests for bigint.magnitude and bigint.decimal.
module magnitude_test;

import bigint.decimal;
import bigint.magnitude;

private uint[] mag(string s)
{
    return parseDecimal(s).magnitude;
}

private string str(const(uint)[] m)
{
    return toDecimal(false, m);
}

unittest // parse / format
{
    assert(parseDecimal("0").magnitude.length == 0);
    assert(!parseDecimal("-000").negative);
    assert(parseDecimal("-007").negative);
    assert(str(mag("000123456789012")) == "123456789012");
    assert(mag("1000000000") == [0u, 1u]);
    assert(toDecimal(true, mag("1000000000000000000")) == "-1000000000000000000");
    assert(toDecimal(false, null) == "0");
}

unittest // add / sub with carries across limbs
{
    assert(str(add(mag("999999999999999999"), mag("1"))) == "1000000000000000000");
    assert(str(add(mag("1"), mag("999999999999999999"))) == "1000000000000000000");
    assert(str(sub(mag("1000000000000000000"), mag("1"))) == "999999999999999999");
    assert(sub(mag("12345678901234567890"), mag("12345678901234567890")).length == 0);
    assert(str(sub(mag("1000000000000000000"), mag("999999999999999999"))) == "1");
}

unittest // compare
{
    assert(compare(mag("5"), mag("7")) == -1);
    assert(compare(mag("1000000000"), mag("999999999")) == 1);
    assert(compare(mag("123456789123456789"), mag("123456789123456789")) == 0);
    assert(compare(mag("123456789123456790"), mag("123456789123456789")) == 1);
}

unittest // multiplication
{
    assert(mul(mag("0"), mag("123")).length == 0);
    assert(str(mul(mag("123456789012345678901234567890"), mag("987654321098765432109876543210")))
            == "121932631137021795226185032733622923332237463801111263526900");
    // (10^k - 1)^2 = 10^2k - 2*10^k + 1
    auto nines = mag("999999999999999999999999999");
    assert(str(mul(nines, nines)) == "999999999999999999999999998000000000000000000000000001");
}

unittest // division: short and long, and Algorithm D add-back-prone cases
{
    auto r = divMod(mag("1000000000000000000000"), mag("7"));
    assert(str(r.quotient) == "142857142857142857142" && str(r.remainder) == "6");

    auto a = mag("121932631137021795226185032733622923332237463801111263526900");
    auto b = mag("987654321098765432109876543210");
    r = divMod(a, b);
    assert(str(r.quotient) == "123456789012345678901234567890" && r.remainder.length == 0);

    // Dividend smaller than divisor.
    r = divMod(mag("5"), mag("1000000000000"));
    assert(r.quotient.length == 0 && str(r.remainder) == "5");

    // Quotient digit estimates that need correction.
    auto big = mag("999999999999999999999999999999999999");
    auto d = mag("999999999000000001");
    r = divMod(big, d);
    assert(compare(add(mul(r.quotient, d), r.remainder), big) == 0);
    assert(compare(r.remainder, d) < 0);
}

unittest // division identity on pseudo-random operands
{
    uint seed = 12345;
    uint next() { seed = seed * 1664525u + 1013904223u; return seed >> 4; }
    foreach (iter; 0 .. 300)
    {
        auto a = new uint[1 + next() % 12];
        auto b = new uint[1 + next() % 6];
        foreach (ref x; a)
            x = (next() & 3) == 0 ? BASE - 1 - next() % 3 : next() % BASE;
        foreach (ref x; b)
            x = (next() & 3) == 0 ? BASE - 1 - next() % 3 : next() % BASE;
        auto ta = trimmed(a);
        auto tb = trimmed(b);
        if (tb.length == 0)
            continue;
        auto r = divMod(ta, tb);
        assert(compare(r.remainder, tb) < 0);
        assert(compare(add(mul(r.quotient, tb), r.remainder), ta) == 0);
    }
}

unittest // pow
{
    assert(str(pow(mag("2"), 10)) == "1024");
    assert(pow(mag("0"), 5).length == 0);
    assert(str(pow(mag("0"), 0)) == "1");
    assert(str(pow(mag("12345"), 0)) == "1");
    assert(str(pow(mag("10"), 30)) == "1" ~ "000000000000000000000000000000");
    assert(str(pow(mag("3"), 100)) == "515377520732011331036461129765621272702107522001");
}
