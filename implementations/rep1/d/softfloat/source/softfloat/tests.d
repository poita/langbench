/**
 * Property and regression tests that exercise the operations together.
 * Compiled only when unit testing (`dub test`).
 */
module softfloat.tests;

version (unittest)
{
    import softfloat;

    /// Exact binary32 pattern for a non-negative integer below 2^24,
    /// built with integer operations only.
    private uint fromInt(uint n)
    {
        import core.bitop : bsr;

        if (n == 0)
            return 0;
        immutable msb = bsr(n);
        immutable frac = (n << (23 - msb)) & fractionMask;
        return pack(false, cast(uint)(127 + msb), frac);
    }

    /// Small deterministic generator (xorshift32), so failures reproduce.
    private struct Rng
    {
        uint state = 2463534242;

        uint next()
        {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            return state;
        }
    }

    unittest // integer values are exact
    {
        foreach (a; 0 .. 200)
            foreach (b; 1 .. 200)
            {
                assert(add(fromInt(a), fromInt(b)) == fromInt(a + b));
                assert(mul(fromInt(a), fromInt(b)) == fromInt(a * b));
                assert(sub(fromInt(a + b), fromInt(b)) == fromInt(a));
                assert(div(fromInt(a * b), fromInt(b)) == fromInt(a));
            }
    }

    unittest // sqrt of perfect squares is exact
    {
        foreach (n; 0 .. 4096)
            assert(sqrt(fromInt(n * n)) == fromInt(n));
    }

    unittest // algebraic identities over random bit patterns
    {
        Rng rng;
        foreach (i; 0 .. 200_000)
        {
            immutable a = rng.next();
            immutable b = rng.next();

            assert(add(a, b) == add(b, a));
            assert(mul(a, b) == mul(b, a));
            assert(sub(a, b) == add(a, negate(b)));
            if (isNaN(add(a, b)))
                assert(add(a, b) == canonicalNaN);

            if (!isNaN(a) && !isInfinity(a))
            {
                assert(sub(a, a) == 0);
                assert(mul(a, 0x3f80_0000) == a); // a * 1
                assert(div(a, 0x3f80_0000) == a); // a / 1
                assert(add(a, negate(a)) == 0);
            }
            if (!isNaN(a) && !isZero(a))
                assert(mul(a, 0x3f80_0000) == a);

            // sqrt(x*x) == |x| whenever x*x neither overflows nor underflows
            // (|x| in [2^-60, 2^60] keeps the square in the normal range).
            immutable e = exponentField(a);
            if (e >= 67 && e <= 187)
                assert(sqrt(mul(a, a)) == (a & ~signMask));
        }
    }

    unittest // ties to even around 1.0
    {
        // 1 + k * 2^-24 rounds to nearest even on the 2^-23 grid.
        enum one = 0x3f80_0000;
        enum uint ulp = 0x3380_0000;   // 2^-24 = half an ulp of 1.0
        assert(add(one, ulp) == one);                    // tie -> even (down)
        assert(add(0x3f80_0001, ulp) == 0x3f80_0002);    // tie -> even (up)
        assert(add(add(one, ulp), ulp) == one);          // two roundings, no accumulation
        assert(add(one, 0x3380_0001) == 0x3f80_0001);    // just over half an ulp
    }

    unittest // gradual underflow
    {
        enum minNormal = 0x0080_0000;
        enum minDenormal = 0x0000_0001;
        assert(div(minNormal, 0x4000_0000) == 0x0040_0000);
        assert(sub(minNormal, minDenormal) == 0x007f_ffff);
        // every denormal is exactly representable: d + d == 2d
        Rng rng;
        foreach (i; 0 .. 10_000)
        {
            immutable d = rng.next() & 0x003f_ffff;
            assert(add(d, d) == d * 2);
            assert(mul(d, 0x4000_0000) == d * 2);
            assert(div(d * 2, 0x4000_0000) == d);
        }
    }

    unittest // overflow and the exact threshold
    {
        assert(mul(0x7f7f_ffff, 0x7f7f_ffff) == 0x7f80_0000);
        assert(mul(0xff7f_ffff, 0x7f7f_ffff) == 0xff80_0000);
        assert(div(0x7f7f_ffff, 0x0080_0000) == 0x7f80_0000);
        assert(add(0x7f7f_ffff, 0x7f7f_ffff) == 0x7f80_0000);
        assert(add(0xff7f_ffff, 0xff7f_ffff) == 0xff80_0000);
    }

    unittest // NaN handling never leaks payloads or signs
    {
        foreach (nan; [0x7f80_0001u, 0x7fc0_0000, 0xffc0_0000, 0xff80_0001, 0x7fff_ffff])
        {
            assert(add(nan, 0x3f80_0000) == canonicalNaN);
            assert(sub(0x3f80_0000, nan) == canonicalNaN);
            assert(mul(nan, 0) == canonicalNaN);
            assert(div(0x7f80_0000, nan) == canonicalNaN);
            assert(sqrt(nan) == canonicalNaN);
        }
    }
}
