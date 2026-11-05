/// Unit tests for bigint.limbs (magnitude algorithms).
module limbs_test;

import bigint.limbs;
import std.array : appender;

private uint[] mag(string s)
{
    uint[] r;
    assert(parseMag(s, r));
    return r;
}

private string str(const(uint)[] m)
{
    auto app = appender!string();
    putMag(app, m);
    return app[];
}

unittest // parse and print round trip
{
    assert(mag("0").length == 0);
    assert(mag("0000").length == 0);
    assert(mag("000000000000000000123") == [123]);
    assert(mag("1000000000") == [0, 1]);
    assert(mag("123456789012345678901") == [345_678_901, 456_789_012, 123]);
    assert(str(mag("123456789012345678901")) == "123456789012345678901");
    assert(str(null) == "0");
    assert(str(mag("1000000000000000000")) == "1000000000000000000");
}

unittest // parse rejects non-digits
{
    uint[] r;
    assert(!parseMag("12a", r));
    assert(!parseMag("-1", r));
}

unittest // compare
{
    assert(cmpMag(mag("5"), mag("5")) == 0);
    assert(cmpMag(mag("5"), mag("6")) < 0);
    assert(cmpMag(mag("1000000000"), mag("999999999")) > 0);
    assert(cmpMag(null, mag("1")) < 0);
}

unittest // add / sub with carries and borrows
{
    assert(str(addMag(mag("999999999"), mag("1"))) == "1000000000");
    assert(str(addMag(mag("999999999999999999"), mag("1"))) == "1000000000000000000");
    assert(str(addMag(null, null)) == "0");
    assert(str(subMag(mag("1000000000000000000"), mag("1"))) == "999999999999999999");
    assert(str(subMag(mag("123"), mag("123"))) == "0");
    assert(subMag(mag("123"), mag("123")).length == 0);
}

unittest // multiplication
{
    assert(str(mulMag(mag("12345678901234567890"), mag("98765432109876543210")))
        == "1219326311370217952237463801111263526900");
    assert(str(mulMag(mag("999999999"), mag("999999999"))) == "999999998000000001");
    assert(mulMag(mag("0"), mag("5")).length == 0);
    // (10^k - 1)^2 = 10^2k - 2*10^k + 1
    string nines = "";
    foreach (_; 0 .. 100)
        nines ~= "9";
    auto p = mulMag(mag(nines), mag(nines));
    assert(str(p) == nines[0 .. 99] ~ "8" ~ zeros(99) ~ "1");
}

private string zeros(size_t n)
{
    string s;
    foreach (_; 0 .. n)
        s ~= "0";
    return s;
}

unittest // short division
{
    uint rem;
    auto q = divShort(mag("1000000000000000000"), 7, rem);
    assert(str(q) == "142857142857142857" && rem == 1);
}

unittest // long division, simple and add-back-prone cases
{
    auto r = divModMag(mag("1000000000000000000000000000"), mag("1000000000000000001"));
    assert(str(r.quotient) == "999999999");
    assert(str(r.remainder) == "999999999000000001");

    // a < b
    r = divModMag(mag("5"), mag("1000000000000"));
    assert(r.quotient.length == 0 && str(r.remainder) == "5");
}

unittest // division identity on structured limb patterns
{
    immutable uint[] pool = [0, 1, 2, 499_999_999, 500_000_000, 999_999_998, 999_999_999];
    uint seed = 12345;
    uint next()
    {
        seed = seed * 1_103_515_245 + 12_345;
        return seed >> 8;
    }

    foreach (iter; 0 .. 3000)
    {
        auto a = new uint[2 + next() % 8];
        auto b = new uint[2 + next() % 5];
        foreach (ref x; a)
            x = pool[next() % pool.length];
        foreach (ref x; b)
            x = pool[next() % pool.length];
        a[$ - 1] = pool[1 + next() % (pool.length - 1)];
        b[$ - 1] = pool[1 + next() % (pool.length - 1)];
        auto qr = divModMag(a, b);
        assert(cmpMag(qr.remainder, b) < 0);
        auto back = addMag(mulMag(qr.quotient, b), qr.remainder);
        assert(cmpMag(back, a) == 0);
    }
}
