/// Unit tests for softfloat.arith, including a randomized cross-check against
/// the host FPU. The FPU is used here only as a test oracle; the library
/// itself never touches floating point.
module softfloat.arith_test;

import std.random : Mt19937, uniform;
import softfloat;

private float asFloat(uint x) @trusted { return *cast(float*) &x; }
private uint asBits(float f) @trusted { return *cast(uint*) &f; }

// Hardware reference with the NaN canonicalised as in the spec.
private uint canon(float f)
{
    immutable b = asBits(f);
    return isNaN(b) ? canonicalNaN : b;
}

unittest // spec example 1
{
    assert(add(0x3f800000, 0x3f800000) == 0x40000000);
    assert(sub(0x3f800000, 0x3f800000) == 0x00000000);
    assert(mul(0x40400000, 0xc0400000) == 0xc1100000);
    assert(div(0x3f800000, 0x40400000) == 0x3eaaaaab);
    assert(sqrt(0x40000000) == 0x3fb504f3);
}

unittest // special values and signed zeros
{
    assert(add(0x7f800000, 0xff800000) == canonicalNaN);
    assert(mul(0x7f800000, 0) == canonicalNaN);
    assert(div(0, 0) == canonicalNaN);
    assert(div(0x7f800000, 0x7f800000) == canonicalNaN);
    assert(sqrt(0x80000000) == 0x80000000);
    assert(sqrt(0xbf800000) == canonicalNaN);
    assert(sqrt(0xff800000) == canonicalNaN);
    assert(sqrt(0x7f800000) == 0x7f800000);
    assert(mul(0, 0xbf800000) == 0x80000000);
    assert(mul(0x80000000, 0x80000000) == 0);
    assert(add(0x80000000, 0x80000000) == 0x80000000);
    assert(add(0x80000000, 0) == 0);
    assert(sub(0x80000000, 0) == 0x80000000);
    assert(sub(0x80000000, 0x80000000) == 0);
    assert(add(0x80000000, 0x3f800000) == 0x3f800000);
    assert(div(0x3f800000, 0) == 0x7f800000);
    assert(div(0x3f800000, 0x80000000) == 0xff800000);
    assert(div(0x80000000, 0x7f800000) == 0x80000000);
    assert(add(0x7fc12345, 0x3f800000) == canonicalNaN);
    assert(add(0x7f800001, 0x3f800000) == canonicalNaN);
    assert(sqrt(0xffc00000) == canonicalNaN);
}

unittest // rounding at the edges (spec example 3)
{
    assert(add(0x7f7fffff, 0x73000000) == 0x7f800000);
    assert(add(0x7f7fffff, 0x72ffffff) == 0x7f7fffff);
    assert(div(0x00000001, 0x40000000) == 0x00000000);
    assert(div(0x00000003, 0x40000000) == 0x00000002);
    assert(add(0x3f800000, 0x33800000) == 0x3f800000);
    assert(add(0x3f800001, 0x33800000) == 0x3f800002);
    assert(add(0x3f800000, 0x33000000) == 0x3f800000);
    assert(mul(0x00000001, 0x3f000000) == 0x00000000);
    assert(mul(0x80000001, 0x3f000000) == 0x80000000);
}

unittest // denormal boundary
{
    assert(sub(0x00800000, 0x00000001) == 0x007fffff);
    assert(add(0x007fffff, 0x00000001) == 0x00800000);
    assert(mul(0x00000001, 0x00000001) == 0);
    assert(sqrt(0x00000001) == 0x1a3504f3);
}

unittest // randomized cross-check against the host FPU
{
    auto rng = Mt19937(12345);
    // Mix of fully random patterns and patterns near interesting exponents.
    uint pick()
    {
        immutable kind = uniform(0, 4, rng);
        uint x = uniform!uint(rng);
        final switch (kind)
        {
        case 0: return x;
        case 1: return x & 0x807fffff;                       // denormals / zeros
        case 2: return (x & 0x807fffff) | (uniform(0, 8, rng) << 23); // tiny exponents
        case 3: return (x & 0x807fffff) | ((120 + uniform(0, 16, rng)) << 23);
        }
    }
    foreach (_; 0 .. 200_000)
    {
        immutable a = pick(), b = pick();
        immutable fa = asFloat(a), fb = asFloat(b);
        assert(add(a, b) == canon(fa + fb), "add");
        assert(sub(a, b) == canon(fa - fb), "sub");
        assert(mul(a, b) == canon(fa * fb), "mul");
        assert(div(a, b) == canon(fa / fb), "div");
        immutable abs = a & 0x7fffffff;
        assert(sqrt(a) == canon(sqrtOracle(fa)), "sqrt");
        assert(sqrt(abs) == canon(sqrtOracle(asFloat(abs))), "sqrt+");
    }
}

private float sqrtOracle(float f) @trusted
{
    import core.stdc.math : sqrtf;
    return sqrtf(f);
}
