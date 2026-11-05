/**
 * Unsigned magnitude arithmetic on little-endian base-10^9 limb arrays.
 *
 * A magnitude is a `uint[]` whose elements are in `[0, 10^9)` and whose most
 * significant element is non-zero; zero is the empty array. All functions
 * here take and return magnitudes in that normalised form. All algorithms are
 * classical quadratic ones (schoolbook multiplication, Knuth Algorithm D).
 */
module bigint.magnitude;

/// The limb base, 10^9. A power of ten keeps decimal I/O linear.
enum uint BASE = 1_000_000_000;
/// Decimal digits per limb.
enum size_t DIGITS_PER_LIMB = 9;

private enum ulong B = BASE;

/// Returns `m` without most-significant zero limbs (no copy).
inout(uint)[] trimmed(inout(uint)[] m) pure nothrow @nogc @safe
{
    size_t n = m.length;
    while (n > 0 && m[n - 1] == 0)
        --n;
    return m[0 .. n];
}

/// Three-way comparison of two normalised magnitudes: -1, 0 or 1.
int compare(scope const(uint)[] a, scope const(uint)[] b) pure nothrow @nogc @safe
{
    if (a.length != b.length)
        return a.length < b.length ? -1 : 1;
    for (size_t i = a.length; i-- > 0;)
    {
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

/// Returns `a + b`.
uint[] add(scope const(uint)[] a, scope const(uint)[] b) pure nothrow @safe
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
        uint s = a[i] + b[i] + carry; // < 2*10^9 fits in uint
        if (s >= BASE)
        {
            s -= BASE;
            carry = 1;
        }
        else
            carry = 0;
        r[i] = s;
    }
    for (; i < a.length; ++i)
    {
        uint s = a[i] + carry;
        if (s >= BASE)
        {
            s -= BASE;
            carry = 1;
        }
        else
            carry = 0;
        r[i] = s;
    }
    r[i] = carry;
    return trimmed(r);
}

/// Returns `a - b`. Requires `a >= b`.
uint[] sub(scope const(uint)[] a, scope const(uint)[] b) pure nothrow @safe
in (compare(a, b) >= 0)
{
    auto r = new uint[a.length];
    uint borrow = 0;
    size_t i = 0;
    for (; i < b.length; ++i)
    {
        int d = cast(int) a[i] - cast(int) b[i] - cast(int) borrow;
        if (d < 0)
        {
            d += BASE;
            borrow = 1;
        }
        else
            borrow = 0;
        r[i] = cast(uint) d;
    }
    for (; i < a.length; ++i)
    {
        int d = cast(int) a[i] - cast(int) borrow;
        if (d < 0)
        {
            d += BASE;
            borrow = 1;
        }
        else
            borrow = 0;
        r[i] = cast(uint) d;
    }
    return trimmed(r);
}

/// Returns `a * b` using the schoolbook method.
uint[] mul(scope const(uint)[] a, scope const(uint)[] b) pure nothrow @safe
{
    if (a.length == 0 || b.length == 0)
        return null;
    // Rows over the shorter operand, columns over the longer one.
    if (a.length < b.length)
    {
        auto t = a;
        a = b;
        b = t;
    }
    auto r = new uint[a.length + b.length];
    foreach (i; 0 .. b.length)
    {
        immutable ulong bi = b[i];
        if (bi == 0)
            continue;
        ulong carry = 0;
        auto row = r[i .. i + a.length + 1];
        foreach (j; 0 .. a.length)
        {
            immutable ulong t = row[j] + a[j] * bi + carry;
            carry = t / B;
            row[j] = cast(uint)(t - carry * B);
        }
        row[a.length] = cast(uint) carry; // slot above the row is still zero
    }
    return trimmed(r);
}

/// Quotient and remainder of a magnitude division.
struct DivMod
{
    uint[] quotient;
    uint[] remainder;
}

/// Divides `a` by a single limb `d` (non-zero). O(n).
DivMod divModLimb(scope const(uint)[] a, uint d) pure nothrow @safe
in (d != 0)
{
    auto q = new uint[a.length];
    ulong rem = 0;
    for (size_t i = a.length; i-- > 0;)
    {
        immutable ulong cur = rem * B + a[i];
        immutable ulong qd = cur / d;
        q[i] = cast(uint) qd;
        rem = cur - qd * d;
    }
    uint[] r = rem == 0 ? null : [cast(uint) rem];
    return DivMod(trimmed(q), r);
}

/**
 * Divides `a` by `b` (non-zero), returning quotient and remainder, with
 * `a == q*b + r` and `r < b`. Uses short division for a one-limb divisor and
 * Knuth's Algorithm D otherwise.
 */
DivMod divMod(scope const(uint)[] a, scope const(uint)[] b) pure nothrow @safe
in (b.length != 0)
{
    if (compare(a, b) < 0)
        return DivMod(null, a.dup);
    if (b.length == 1)
        return divModLimb(a, b[0]);

    immutable size_t n = b.length;
    immutable size_t L = a.length;
    immutable uint d = cast(uint)(B / (b[n - 1] + 1UL));

    // Normalised working copies: u has L+1 limbs, v has n limbs.
    auto u = new uint[L + 1];
    auto v = new uint[n];
    {
        ulong carry = 0;
        foreach (i; 0 .. L)
        {
            immutable ulong p = a[i] * cast(ulong) d + carry;
            carry = p / B;
            u[i] = cast(uint)(p - carry * B);
        }
        u[L] = cast(uint) carry;
        carry = 0;
        foreach (i; 0 .. n)
        {
            immutable ulong p = b[i] * cast(ulong) d + carry;
            carry = p / B;
            v[i] = cast(uint)(p - carry * B);
        }
        assert(carry == 0);
    }

    auto q = new uint[L - n + 1];
    immutable ulong vTop = v[n - 1];
    immutable ulong vSecond = v[n - 2];

    for (size_t j = L - n + 1; j-- > 0;)
    {
        immutable ulong num = u[j + n] * B + u[j + n - 1];
        ulong qhat = num / vTop;
        ulong rhat = num - qhat * vTop;
        while (qhat >= B || qhat * vSecond > rhat * B + u[j + n - 2])
        {
            --qhat;
            rhat += vTop;
            if (rhat >= B)
                break;
        }

        // u[j .. j+n+1] -= qhat * v, fused multiply-subtract.
        auto w = u[j .. j + n + 1];
        ulong carry = 0;
        uint borrow = 0;
        foreach (i; 0 .. n)
        {
            immutable ulong p = qhat * v[i] + carry;
            carry = p / B;
            immutable uint lo = cast(uint)(p - carry * B);
            int s = cast(int) w[i] - cast(int) lo - cast(int) borrow;
            if (s < 0)
            {
                s += BASE;
                borrow = 1;
            }
            else
                borrow = 0;
            w[i] = cast(uint) s;
        }
        long top = cast(long) w[n] - cast(long) carry - borrow;
        if (top < 0)
        {
            // qhat was one too large: add v back once.
            --qhat;
            uint c = 0;
            foreach (i; 0 .. n)
            {
                uint s = w[i] + v[i] + c;
                if (s >= BASE)
                {
                    s -= BASE;
                    c = 1;
                }
                else
                    c = 0;
                w[i] = s;
            }
            top += c; // the carry out cancels the earlier borrow
        }
        w[n] = cast(uint) top;
        q[j] = cast(uint) qhat;
    }

    // Remainder: low n limbs of u, divided by d.
    auto r = divModLimb(trimmed(u[0 .. n]), d).quotient;
    return DivMod(trimmed(q), r);
}

/// Returns `a ^ e` for a magnitude `a` and machine exponent `e`
/// (left-to-right binary exponentiation).
uint[] pow(scope const(uint)[] a, ulong e) pure nothrow @safe
{
    if (e == 0)
        return [1u];
    if (a.length == 0)
        return null;
    if (a.length == 1 && a[0] == 1)
        return [1u];
    uint[] acc = a.dup;
    int top = 63;
    while (((e >> top) & 1) == 0)
        --top;
    for (int bit = top - 1; bit >= 0; --bit)
    {
        acc = mul(acc, acc);
        if ((e >> bit) & 1)
            acc = mul(acc, a);
    }
    return acc;
}
