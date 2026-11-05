/**
 * Unsigned magnitudes: little-endian arrays of base-10^9 limbs.
 *
 * A magnitude is a `uint[]` whose elements are all in `[0, 10^9)` and whose
 * most significant limb is non-zero; zero is the empty array. Every function
 * here takes and returns magnitudes in that canonical (trimmed) form, and none
 * of them modifies its arguments.
 */
module bigint.magnitude;

/// A little-endian sequence of base-10^9 limbs.
alias Limbs = uint[];

/// The limb base, 10^9: the largest power of ten whose products fit in 64 bits.
enum uint BASE = 1_000_000_000;

/// Number of decimal digits held by one limb.
enum size_t LIMB_DIGITS = 9;

/// Removes most-significant zero limbs (returns a slice of the same memory).
inout(uint)[] trim(inout(uint)[] a) pure nothrow @nogc @safe
{
    size_t n = a.length;
    while (n > 0 && a[n - 1] == 0)
        --n;
    return a[0 .. n];
}

/// Three-way comparison of two magnitudes: -1, 0 or 1.
int cmpMag(scope const(uint)[] a, scope const(uint)[] b) pure nothrow @nogc @safe
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
Limbs addMag(scope const(uint)[] a, scope const(uint)[] b) pure nothrow @safe
{
    if (a.length < b.length)
    {
        auto t = a;
        a = b;
        b = t;
    }
    // a is now the longer operand.
    auto r = new uint[a.length + 1];
    uint carry = 0;
    size_t i = 0;
    for (; i < b.length; ++i)
    {
        uint s = a[i] + b[i] + carry; // < 2*10^9 + 1, fits in uint
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
    r[a.length] = carry;
    return trim(r);
}

/// Returns `a - b`. Requires `a >= b` (as magnitudes).
Limbs subMag(scope const(uint)[] a, scope const(uint)[] b) pure nothrow @safe
in (cmpMag(a, b) >= 0, "subMag requires a >= b")
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
    return trim(r);
}

/**
 * Returns `a * b` using the classical quadratic algorithm.
 *
 * Rows run over the limbs of the shorter operand so that the inner loop is the
 * long one; rows whose multiplier limb is zero are skipped.
 */
Limbs mulMag(scope const(uint)[] a, scope const(uint)[] b) pure nothrow @trusted
{
    if (a.length == 0 || b.length == 0)
        return null;
    if (a.length > b.length)
    {
        auto t = a;
        a = b;
        b = t;
    }
    // a is the shorter operand (rows), b the longer (columns).
    immutable size_t n = a.length, m = b.length;
    auto r = new uint[n + m];
    const(uint)* bp = b.ptr;
    for (size_t i = 0; i < n; ++i)
    {
        immutable ulong x = a[i];
        if (x == 0)
            continue;
        uint* rp = r.ptr + i;
        ulong carry = 0;
        for (size_t j = 0; j < m; ++j)
        {
            ulong t = rp[j] + x * bp[j] + carry;
            carry = t / BASE;
            rp[j] = cast(uint)(t - carry * BASE);
        }
        rp[m] = cast(uint) carry; // that limb is still zero
    }
    return trim(r);
}
