/**
 * Unsigned multi-precision arithmetic on little-endian base-10^9 limb vectors.
 *
 * A "magnitude" is a `uint[]` whose elements are all `< BASE`, least
 * significant limb first, with no most-significant zero limbs; zero is the
 * empty array. Every function here expects normalised inputs and returns a
 * normalised, freshly allocated result (inputs are never modified).
 */
module bigint.magnitude;

/// Limb radix.
enum uint BASE = 1_000_000_000;
/// Decimal digits per limb.
enum size_t BASE_DIGITS = 9;

@safe pure nothrow
{

/// Returns `a` without its most significant zero limbs.
inout(uint)[] trim(return inout(uint)[] a) @nogc
{
    size_t n = a.length;
    while (n > 0 && a[n - 1] == 0)
        --n;
    return a[0 .. n];
}

/// Three-way comparison of two magnitudes: -1, 0 or 1.
int cmpMag(const(uint)[] a, const(uint)[] b) @nogc
{
    if (a.length != b.length)
        return a.length < b.length ? -1 : 1;
    for (size_t i = a.length; i > 0; --i)
    {
        if (a[i - 1] != b[i - 1])
            return a[i - 1] < b[i - 1] ? -1 : 1;
    }
    return 0;
}

/// Returns `a + b`. O(a.length + b.length).
uint[] addMag(const(uint)[] a, const(uint)[] b)
{
    if (a.length < b.length)
    {
        auto t = a;
        a = b;
        b = t;
    }
    auto r = new uint[a.length + 1];
    uint carry = 0;
    size_t i = 0;
    for (; i < b.length; ++i)
    {
        uint s = a[i] + b[i] + carry; // < 2*BASE < 2^32
        carry = s >= BASE;
        r[i] = carry ? s - BASE : s;
    }
    for (; i < a.length; ++i)
    {
        uint s = a[i] + carry;
        carry = s >= BASE;
        r[i] = carry ? s - BASE : s;
    }
    r[i] = carry;
    return trim(r);
}

/// Returns `a - b`; requires `a >= b`. O(a.length).
uint[] subMag(const(uint)[] a, const(uint)[] b)
in (cmpMag(a, b) >= 0)
{
    auto r = new uint[a.length];
    uint borrow = 0;
    size_t i = 0;
    for (; i < b.length; ++i)
    {
        uint x = a[i];
        uint y = b[i] + borrow; // <= BASE
        borrow = x < y;
        r[i] = borrow ? x + BASE - y : x - y;
    }
    for (; i < a.length; ++i)
    {
        const uint x = a[i];
        if (borrow && x == 0)
        {
            r[i] = BASE - 1; // keeps borrowing
        }
        else
        {
            r[i] = x - borrow;
            borrow = 0;
        }
    }
    return trim(r);
}

/// Returns `a * b` by schoolbook long multiplication. O(a.length * b.length).
uint[] mulMag(const(uint)[] a, const(uint)[] b)
{
    if (a.length == 0 || b.length == 0)
        return null;
    if (a.length > b.length)
    {
        auto t = a;
        a = b;
        b = t;
    }
    // Outer loop over the shorter operand, inner loop over the longer one.
    auto r = new uint[a.length + b.length];
    foreach (i; 0 .. a.length)
    {
        const ulong ai = a[i];
        if (ai == 0)
            continue;
        ulong carry = 0;
        auto row = r[i .. i + b.length];
        foreach (j; 0 .. b.length)
        {
            // <= (B-1) + (B-1)^2 + (B-1) < 2^64
            const ulong cur = row[j] + ai * b[j] + carry;
            carry = cur / BASE;
            row[j] = cast(uint)(cur - carry * BASE);
        }
        r[i + b.length] = cast(uint) carry; // untouched by earlier rows
    }
    return trim(r);
}

/// Returns `a * m` for a single limb `m < BASE`.
uint[] mulSmall(const(uint)[] a, uint m)
{
    if (a.length == 0 || m == 0)
        return null;
    auto r = new uint[a.length + 1];
    ulong carry = 0;
    foreach (i; 0 .. a.length)
    {
        const ulong cur = cast(ulong) a[i] * m + carry;
        carry = cur / BASE;
        r[i] = cast(uint)(cur - carry * BASE);
    }
    r[a.length] = cast(uint) carry;
    return trim(r);
}

/// Divides `a` by the single limb `d` (non-zero); returns the quotient and stores the remainder.
uint[] divModSmall(const(uint)[] a, uint d, out uint rem)
in (d != 0 && d < BASE)
{
    auto q = new uint[a.length];
    ulong r = 0;
    for (size_t i = a.length; i > 0; --i)
    {
        const ulong cur = r * BASE + a[i - 1];
        const ulong qd = cur / d;
        q[i - 1] = cast(uint) qd;
        r = cur - qd * d;
    }
    rem = cast(uint) r;
    return trim(q);
}

/**
 * Quotient and remainder of `a / b` (Knuth, TAOCP vol. 2, 4.3.1, Algorithm D),
 * with `b` non-zero. Each quotient limb is obtained in constant time from an
 * estimate that is off by at most one before correction.
 * Complexity O((a.length - b.length + 1) * b.length).
 */
void divModMag(const(uint)[] a, const(uint)[] b, out uint[] quot, out uint[] rem)
in (b.length > 0)
{
    if (cmpMag(a, b) < 0)
    {
        quot = null;
        rem = a.dup;
        return;
    }
    if (b.length == 1)
    {
        uint r;
        quot = divModSmall(a, b[0], r);
        rem = r == 0 ? null : [r];
        return;
    }

    const size_t n = b.length;
    const size_t m = a.length - n;

    // D1: normalise so that the top divisor limb is >= BASE / 2.
    const uint d = BASE / (b[n - 1] + 1);
    auto v = new uint[n];
    auto u = new uint[a.length + 1];
    {
        ulong carry = 0;
        foreach (i; 0 .. n)
        {
            const ulong cur = cast(ulong) b[i] * d + carry;
            carry = cur / BASE;
            v[i] = cast(uint)(cur - carry * BASE);
        }
        assert(carry == 0);
        carry = 0;
        foreach (i; 0 .. a.length)
        {
            const ulong cur = cast(ulong) a[i] * d + carry;
            carry = cur / BASE;
            u[i] = cast(uint)(cur - carry * BASE);
        }
        u[a.length] = cast(uint) carry;
    }

    const ulong vTop = v[n - 1];
    const ulong vSecond = v[n - 2];
    auto q = new uint[m + 1];

    for (size_t j = m + 1; j-- > 0;)
    {
        // D3: estimate the quotient limb.
        const ulong num = u[j + n] * cast(ulong) BASE + u[j + n - 1];
        ulong qhat = num / vTop;
        ulong rhat = num - qhat * vTop;
        while (qhat >= BASE || qhat * vSecond > rhat * BASE + u[j + n - 2])
        {
            --qhat;
            rhat += vTop;
            if (rhat >= BASE)
                break;
        }

        // D4: multiply and subtract qhat * v from u[j .. j+n].
        uint borrow = 0;
        ulong carry = 0;
        auto uj = u[j .. j + n + 1];
        foreach (i; 0 .. n)
        {
            const ulong p = qhat * v[i] + carry;
            carry = p / BASE;
            const uint sub = cast(uint)(p - carry * BASE) + borrow; // <= BASE
            borrow = uj[i] < sub;
            uj[i] = borrow ? uj[i] + BASE - sub : uj[i] - sub;
        }
        {
            const uint sub = cast(uint) carry + borrow;
            borrow = uj[n] < sub;
            uj[n] = borrow ? uj[n] + BASE - sub : uj[n] - sub;
        }

        // D5/D6: if the subtraction went negative, add the divisor back once.
        if (borrow)
        {
            --qhat;
            uint c = 0;
            foreach (i; 0 .. n)
            {
                uint s = uj[i] + v[i] + c;
                c = s >= BASE;
                uj[i] = c ? s - BASE : s;
            }
            // The carry out cancels the earlier borrow.
            uj[n] = (uj[n] + c) % BASE;
        }
        q[j] = cast(uint) qhat;
    }

    // D8: the remainder is u[0 .. n] divided by the normalisation factor.
    uint dummy;
    quot = trim(q);
    rem = divModSmall(trim(u[0 .. n]), d, dummy);
    assert(dummy == 0);
}

} // @safe pure nothrow

version (unittest)
{
    private uint[] fromUlong(ulong v)
    {
        uint[] r;
        while (v)
        {
            r ~= cast(uint)(v % BASE);
            v /= BASE;
        }
        return r;
    }
}

unittest
{
    // add / sub with carries and borrows across limbs
    auto a = [BASE - 1, BASE - 1, BASE - 1];
    assert(addMag(a, [1u]) == [0u, 0, 0, 1]);
    assert(subMag([0u, 0, 0, 1], [1u]) == a);
    assert(subMag(a, a).length == 0);
    assert(addMag(null, null).length == 0);
    assert(addMag([5u], a) == [4u, 0, 0, 1]);
}

unittest
{
    assert(mulMag([BASE - 1], [BASE - 1]) == [1u, BASE - 2]);
    assert(mulMag(null, [3u]).length == 0);
    assert(mulMag(fromUlong(12_345_678_901UL), fromUlong(987_654_321UL))
            == fromUlong(12_345_678_901UL * 987_654_321UL));
    assert(mulSmall([BASE - 1, BASE - 1], BASE - 1) == [1u, BASE - 1, BASE - 2]);
}

unittest
{
    // (B^3 - 1) / (B^2 - 1) hits the qhat-correction paths
    uint[] q, r;
    auto a = [BASE - 1, BASE - 1, BASE - 1];
    auto b = [BASE - 1, BASE - 1];
    divModMag(a, b, q, r);
    assert(addMag(mulMag(q, b), r) == a);
    assert(cmpMag(r, b) < 0);

    // the classic add-back case for base 2^32 analogue: u = B^4/2 style values
    auto big = [0u, 0, 0, BASE / 2 + 0];
    auto dv = [1u, 0, BASE / 2];
    divModMag(big, dv, q, r);
    assert(addMag(mulMag(q, dv), r) == big);
    assert(cmpMag(r, dv) < 0);
}

unittest
{
    // randomised identity check a == q*b + r, r < b
    import std.random : Mt19937, uniform;

    auto rng = Mt19937(12345);
    uint[] randMag(size_t len)
    {
        auto r = new uint[len];
        foreach (ref x; r)
        {
            switch (uniform(0, 4, rng))
            {
            case 0:
                x = 0;
                break;
            case 1:
                x = BASE - 1;
                break;
            case 2:
                x = uniform(0, 3u, rng);
                break;
            default:
                x = uniform(0, BASE, rng);
            }
        }
        return trim(r).dup;
    }

    foreach (iter; 0 .. 3000)
    {
        auto a = randMag(uniform(0, 14, rng));
        auto b = randMag(uniform(1, 9, rng));
        if (b.length == 0)
            continue;
        uint[] q, r;
        divModMag(a, b, q, r);
        assert(cmpMag(r, b) < 0);
        assert(addMag(mulMag(q, b), r) == a);
    }
}
