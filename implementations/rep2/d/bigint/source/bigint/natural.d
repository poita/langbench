/**
 * Low-level arithmetic on natural numbers (non-negative integers).
 *
 * A natural number is a little-endian array of limbs in base 10^9. A
 * *normalised* number has no most-significant zero limb, so zero is the empty
 * array. Every function here expects normalised inputs and returns normalised
 * outputs. Base 10^9 keeps decimal parsing and printing linear in the number
 * of digits while a limb product still fits comfortably in a `ulong`.
 *
 * Most users want the signed $(REF BigInt, bigint.bigint) type instead.
 */
module bigint.natural;

/// Number of decimal digits stored in each limb.
enum uint limbDigits = 9;

/// The limb radix, 10^9.
enum uint limbBase = 1_000_000_000;

/// A natural number: little-endian limbs in base 10^9, no high zero limb.
alias Natural = uint[];

/// Removes high zero limbs so the value is normalised.
Natural normalized(Natural a) pure nothrow @nogc @safe
{
    size_t n = a.length;
    while (n > 0 && a[n - 1] == 0)
        --n;
    return a[0 .. n];
}

/// Builds a natural number from an unsigned machine word.
Natural fromUlong(ulong v) pure nothrow @safe
{
    Natural r;
    while (v != 0)
    {
        r ~= cast(uint)(v % limbBase);
        v /= limbBase;
    }
    return r;
}

/// Converts to `ulong`; returns false when the value does not fit.
bool toUlong(const(uint)[] a, out ulong result) pure nothrow @nogc @safe
{
    // 10^9 * 10^9 * 10^9 > 2^64, so more than three limbs can never fit.
    result = 0;
    if (a.length > 3)
        return false;
    foreach_reverse (limb; a)
    {
        immutable ulong hi = result;
        // result * limbBase + limb must not overflow
        if (hi > (ulong.max - limb) / limbBase)
            return false;
        result = hi * limbBase + limb;
    }
    return true;
}

/// Three-way comparison: -1, 0 or 1.
int compare(const(uint)[] a, const(uint)[] b) pure nothrow @nogc @safe
{
    if (a.length != b.length)
        return a.length < b.length ? -1 : 1;
    foreach_reverse (i; 0 .. a.length)
    {
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

/// Returns a + b in O(a.length + b.length).
Natural add(const(uint)[] a, const(uint)[] b) pure nothrow @safe
{
    if (a.length < b.length)
        return add(b, a);
    auto r = new uint[a.length + 1];
    uint carry = 0;
    foreach (i; 0 .. a.length)
    {
        uint s = a[i] + carry + (i < b.length ? b[i] : 0);
        if (s >= limbBase)
        {
            s -= limbBase;
            carry = 1;
        }
        else
            carry = 0;
        r[i] = s;
    }
    r[a.length] = carry;
    return normalized(r);
}

/// Returns a - b in O(a.length). Requires a >= b.
Natural sub(const(uint)[] a, const(uint)[] b) pure nothrow @safe
in (compare(a, b) >= 0, "sub: minuend is smaller than subtrahend")
{
    auto r = new uint[a.length];
    uint borrow = 0;
    foreach (i; 0 .. a.length)
    {
        immutable int d = cast(int) a[i] - cast(int) borrow - (i < b.length ? cast(int) b[i] : 0);
        if (d < 0)
        {
            r[i] = cast(uint)(d + cast(int) limbBase);
            borrow = 1;
        }
        else
        {
            r[i] = cast(uint) d;
            borrow = 0;
        }
    }
    return normalized(r);
}

/// Returns a * m for a single limb `m` (m < 10^9).
Natural mulSmall(const(uint)[] a, uint m) pure nothrow @safe
in (m < limbBase)
{
    if (a.length == 0 || m == 0)
        return null;
    auto r = new uint[a.length + 1];
    ulong carry = 0;
    foreach (i; 0 .. a.length)
    {
        immutable ulong cur = cast(ulong) a[i] * m + carry;
        carry = cur / limbBase;
        r[i] = cast(uint)(cur - carry * limbBase);
    }
    r[a.length] = cast(uint) carry;
    return normalized(r);
}

/// Divides by a single non-zero limb `d` (d < 10^9); the remainder goes to `rem`.
Natural divSmall(const(uint)[] a, uint d, out uint rem) pure nothrow @safe
in (d != 0 && d < limbBase)
{
    auto q = new uint[a.length];
    ulong r = 0;
    foreach_reverse (i; 0 .. a.length)
    {
        immutable ulong cur = r * limbBase + a[i];
        immutable ulong qd = cur / d;
        q[i] = cast(uint) qd;
        r = cur - qd * d;
    }
    rem = cast(uint) r;
    return normalized(q);
}

/// Schoolbook multiplication, O(a.length * b.length).
Natural mul(const(uint)[] a, const(uint)[] b) pure nothrow @safe
{
    if (a.length == 0 || b.length == 0)
        return null;
    if (a.length < b.length)
        return mul(b, a);
    // Outer loop over the shorter operand, inner loop over the longer one.
    auto r = new uint[a.length + b.length];
    foreach (j; 0 .. b.length)
    {
        immutable ulong bj = b[j];
        if (bj == 0)
            continue;
        ulong carry = 0;
        auto row = r[j .. j + a.length];
        foreach (i; 0 .. a.length)
        {
            immutable ulong cur = row[i] + bj * a[i] + carry;
            carry = cur / limbBase;
            row[i] = cast(uint)(cur - carry * limbBase);
        }
        // r[j + a.length] has not been written by any earlier row.
        r[j + a.length] = cast(uint) carry;
    }
    return normalized(r);
}

/**
 * Long division (Knuth, TAOCP vol. 2, Algorithm D): computes the quotient and
 * remainder of `a / b` together in O((a.length - b.length + 1) * b.length).
 * Each quotient limb is estimated from the top two limbs in constant time.
 *
 * Params:
 *     a = dividend
 *     b = divisor, must be non-zero
 *     quotient = receives `a / b`
 *     remainder = receives `a % b`
 */
void divMod(const(uint)[] a, const(uint)[] b, out Natural quotient, out Natural remainder)
    pure nothrow @safe
in (b.length != 0, "divMod: division by zero")
{
    if (compare(a, b) < 0)
    {
        quotient = null;
        remainder = a.dup;
        return;
    }
    if (b.length == 1)
    {
        uint rem;
        quotient = divSmall(a, b[0], rem);
        remainder = rem != 0 ? [rem] : null;
        return;
    }

    immutable n = b.length;
    immutable m = a.length - n;

    // D1: normalise so the divisor's top limb is >= base/2.
    immutable uint d = limbBase / (b[n - 1] + 1);
    auto v = new uint[n];
    auto u = new uint[a.length + 1];
    scale(v, b, d);
    scale(u, a, d);

    immutable ulong vTop = v[n - 1];
    immutable ulong vNext = v[n - 2];
    auto q = new uint[m + 1];

    foreach_reverse (j; 0 .. m + 1)
    {
        // D3: estimate the quotient limb from the top two limbs of the window.
        immutable ulong num = u[j + n] * cast(ulong) limbBase + u[j + n - 1];
        ulong qhat = num / vTop;
        ulong rhat = num - qhat * vTop;
        while (qhat >= limbBase || qhat * vNext > rhat * limbBase + u[j + n - 2])
        {
            --qhat;
            rhat += vTop;
            if (rhat >= limbBase)
                break;
        }

        // D4: multiply and subtract qhat * v from the window u[j .. j + n].
        long borrow = 0;
        ulong carry = 0;
        foreach (i; 0 .. n)
        {
            immutable ulong p = qhat * v[i] + carry;
            carry = p / limbBase;
            long t = cast(long) u[i + j] - borrow - cast(long)(p - carry * limbBase);
            if (t < 0)
            {
                t += limbBase;
                borrow = 1;
            }
            else
                borrow = 0;
            u[i + j] = cast(uint) t;
        }
        long top = cast(long) u[j + n] - borrow - cast(long) carry;
        if (top < 0)
        {
            top += limbBase;
            borrow = 1;
        }
        else
            borrow = 0;
        u[j + n] = cast(uint) top;

        // D5/D6: qhat was one too large (rare): add the divisor back.
        if (borrow)
        {
            --qhat;
            uint c = 0;
            foreach (i; 0 .. n)
            {
                uint s = u[i + j] + v[i] + c;
                if (s >= limbBase)
                {
                    s -= limbBase;
                    c = 1;
                }
                else
                    c = 0;
                u[i + j] = s;
            }
            // Discard the carry out of the window: it cancels the borrow.
            u[j + n] = (u[j + n] + c) % limbBase;
        }
        q[j] = cast(uint) qhat;
    }

    // D8: the remainder is the low n limbs of u, un-normalised.
    uint ignored;
    quotient = normalized(q);
    remainder = divSmall(normalized(u[0 .. n]), d, ignored);
}

// Writes a * m into `dst`, which must have room for a.length or a.length + 1 limbs.
private void scale(uint[] dst, const(uint)[] a, uint m) pure nothrow @nogc @safe
{
    ulong carry = 0;
    foreach (i; 0 .. a.length)
    {
        immutable ulong cur = cast(ulong) a[i] * m + carry;
        carry = cur / limbBase;
        dst[i] = cast(uint)(cur - carry * limbBase);
    }
    if (dst.length > a.length)
        dst[a.length] = cast(uint) carry;
}

/// Raises `base` to the power `exponent` by repeated squaring.
Natural pow(const(uint)[] base, ulong exponent) pure nothrow @safe
{
    if (exponent == 0)
        return [1u];
    if (base.length == 0)
        return null;
    Natural result = [1u];
    // Left-to-right binary exponentiation: O(log exponent) multiplications.
    bool started = false;
    foreach_reverse (bit; 0 .. 64)
    {
        if (started)
            result = mul(result, result);
        if ((exponent >> bit) & 1)
        {
            result = started ? mul(result, base) : base.dup;
            started = true;
        }
    }
    return result;
}

// ---------------------------------------------------------------- tests

version (unittest)
{
    private Natural nat(ulong v) pure nothrow @safe
    {
        return fromUlong(v);
    }
}

@("natural: fromUlong/toUlong round trip")
unittest
{
    foreach (v; [0UL, 1, 999_999_999, 1_000_000_000, 1_000_000_001,
            1_000_000_000_000_000_000, ulong.max])
    {
        ulong back;
        assert(toUlong(nat(v), back));
        assert(back == v);
    }
    ulong x;
    // 2^64 = 18446744073709551616 does not fit
    assert(!toUlong([709_551_616u, 446_744_073u, 18u], x));
    assert(!toUlong([1u, 0, 0, 1], x));
}

@("natural: add and sub carry across limbs")
unittest
{
    auto a = nat(999_999_999_999_999_999);
    assert(add(a, [1u]) == nat(1_000_000_000_000_000_000));
    assert(sub(nat(1_000_000_000_000_000_000), [1u]) == a);
    assert(sub(a, a).length == 0);
    assert(add(null, null).length == 0);
}

@("natural: mul matches machine arithmetic")
unittest
{
    ulong[] xs = [0, 1, 7, 999_999_999, 1_000_000_000, 123_456_789_012];
    foreach (x; xs)
        foreach (y; xs)
        {
            // keep the product within 64 bits
            if (x != 0 && y > ulong.max / x)
                continue;
            assert(mul(nat(x), nat(y)) == nat(x * y));
        }
}

@("natural: divMod satisfies a == q*b + r and r < b")
unittest
{
    // Deterministic pseudo-random operands of varying lengths.
    uint seed = 12345;
    uint next() { seed = seed * 1_664_525 + 1_013_904_223; return seed; }
    foreach (iter; 0 .. 400)
    {
        auto a = new uint[1 + next() % 12];
        auto b = new uint[1 + next() % 8];
        foreach (ref l; a) l = next() % limbBase;
        foreach (ref l; b) l = (next() % 3 == 0) ? limbBase - 1 - next() % 2 : next() % limbBase;
        // sprinkle zero limbs to exercise add-back and estimate corrections
        if (next() % 4 == 0 && b.length > 2) b[1] = 0;
        a = normalized(a);
        b = normalized(b);
        if (b.length == 0)
            continue;
        Natural q, r;
        divMod(a, b, q, r);
        assert(compare(r, b) < 0);
        assert(add(mul(q, b), r) == a);
    }
}

@("natural: divMod hits the add-back correction")
unittest
{
    // Classic Algorithm D add-back case in base 10^9: u = B^3 - 1 style values.
    immutable B1 = limbBase - 1;
    auto b = [B1, B1 - 1, B1 / 2 + 1]; // high limb >= B/2
    auto a = [0u, 0u, 0u, B1 / 2 + 1];
    Natural q, r;
    divMod(a, b, q, r);
    assert(compare(r, b) < 0);
    assert(add(mul(q, b), r) == a);

    uint[] a2 = [B1, B1, B1, B1, B1];
    auto b2 = [B1, B1, B1];
    divMod(a2, b2, q, r);
    assert(add(mul(q, b2), r) == normalized(a2));
    assert(compare(r, b2) < 0);
}

@("natural: pow")
unittest
{
    assert(pow([2u], 10) == nat(1024));
    assert(pow([10u], 18) == nat(1_000_000_000_000_000_000));
    assert(pow(null, 0) == [1u]);
    assert(pow(null, 5).length == 0);
    assert(pow([7u], 1) == [7u]);
    assert(pow([3u], 40) == nat(12_157_665_459_056_928_801));
}
