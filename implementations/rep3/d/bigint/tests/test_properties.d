/// Randomised identity checks (deterministic seed) for BigInt.
module tests.test_properties;

import bigint;

private struct Rng
{
    ulong s = 0x9E3779B97F4A7C15UL;
    ulong next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
}

/// Random decimal string with up to `maxDigits` digits; digit runs biased
/// towards 0 and 9 to provoke carries, borrows and quotient-digit corrections.
private string randomNumber(ref Rng rng, size_t maxDigits)
{
    immutable len = 1 + rng.next() % maxDigits;
    auto buf = new char[len + 1];
    size_t p = 0;
    if (rng.next() % 2) buf[p++] = '-';
    foreach (i; 0 .. len)
    {
        immutable k = rng.next() % 8;
        buf[p++] = k == 0 ? '0' : k == 1 ? '9' : cast(char)('0' + rng.next() % 10);
    }
    return cast(string) buf[0 .. p].idup;
}

unittest // a == (a/b)*b + a%b, |r| < |b|, sign of r
{
    Rng rng;
    foreach (iter; 0 .. 3000)
    {
        auto a = BigInt(randomNumber(rng, iter % 7 == 0 ? 400 : 60));
        auto b = BigInt(randomNumber(rng, iter % 5 == 0 ? 200 : 40));
        if (b.isZero) continue;
        BigInt q, r;
        divMod(a, b, q, r);
        assert(q * b + r == a);
        assert(r.abs < b.abs);
        assert(r.isZero || r.isNegative == a.isNegative);
    }
}

unittest // ring identities
{
    Rng rng;
    foreach (iter; 0 .. 1000)
    {
        auto a = BigInt(randomNumber(rng, 120));
        auto b = BigInt(randomNumber(rng, 120));
        auto c = BigInt(randomNumber(rng, 60));
        assert(a + b == b + a);
        assert((a + b) - b == a);
        assert(a * b == b * a);
        assert(a * (b + c) == a * b + a * c);
        assert((a - b).opCmp(BigInt(0)) == a.opCmp(b));
        assert(BigInt(a.toString()) == a);
    }
}

unittest // pow agrees with repeated multiplication
{
    Rng rng;
    foreach (iter; 0 .. 100)
    {
        auto a = BigInt(randomNumber(rng, 30));
        auto e = cast(ulong)(rng.next() % 12);
        BigInt expect = BigInt(1);
        foreach (i; 0 .. e) expect = expect * a;
        assert(pow(a, e) == expect);
    }
}

unittest // algorithm D add-back path: divisors with top limb just over BASE/2
{
    // u = v * q + r with q, r chosen to stress qhat estimation.
    auto v = BigInt("500000000" ~ "000000000" ~ "000000001");
    auto q = BigInt("999999999999999999");
    auto r = v - BigInt(1);
    auto u = v * q + r;
    BigInt qq, rr;
    divMod(u, v, qq, rr);
    assert(qq == q && rr == r);
}
