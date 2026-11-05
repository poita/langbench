/**
 * Division of magnitudes: short division and Knuth's Algorithm D in base 10^9.
 */
module bigint.division;

import bigint.magnitude;

/**
 * Divides `a` by a single limb `d` (`0 < d < BASE`), from the top limb down.
 *
 * Returns: the quotient; `rem` receives the remainder.
 */
Limbs divModLimb(scope const(uint)[] a, uint d, out uint rem) pure nothrow @safe
in (d != 0 && d < BASE)
{
    auto q = new uint[a.length];
    ulong r = 0;
    for (size_t i = a.length; i-- > 0;)
    {
        immutable ulong cur = r * BASE + a[i];
        immutable ulong qd = cur / d;
        q[i] = cast(uint) qd;
        r = cur - qd * d;
    }
    rem = cast(uint) r;
    return trim(q);
}

/**
 * Divides magnitude `u` by magnitude `v` (`v` must be non-empty).
 *
 * Params:
 *   u = dividend
 *   v = divisor, non-zero
 *   q = receives the quotient `u / v`
 *   r = receives the remainder `u % v`
 */
void divModMag(scope const(uint)[] u, scope const(uint)[] v, out Limbs q, out Limbs r)
    pure nothrow @trusted
in (v.length > 0, "division by zero")
{
    if (cmpMag(u, v) < 0)
    {
        q = null;
        r = u.dup;
        return;
    }
    if (v.length == 1)
    {
        uint rem;
        q = divModLimb(u, v[0], rem);
        r = rem == 0 ? null : [rem];
        return;
    }

    immutable size_t n = u.length, m = v.length;

    // Normalise so that the divisor's top limb is >= BASE/2.
    immutable ulong d = BASE / (cast(ulong) v[m - 1] + 1);
    auto un = new uint[n + 1];
    auto vn = new uint[m];
    {
        ulong carry = 0;
        for (size_t i = 0; i < n; ++i)
        {
            ulong t = u[i] * d + carry;
            carry = t / BASE;
            un[i] = cast(uint)(t - carry * BASE);
        }
        un[n] = cast(uint) carry;
        carry = 0;
        for (size_t i = 0; i < m; ++i)
        {
            ulong t = v[i] * d + carry;
            carry = t / BASE;
            vn[i] = cast(uint)(t - carry * BASE);
        }
        assert(carry == 0);
    }

    auto quo = new uint[n - m + 1];
    immutable ulong vTop = vn[m - 1];
    immutable ulong vSecond = vn[m - 2];
    uint* unp = un.ptr;
    const(uint)* vp = vn.ptr;

    for (size_t j = n - m + 1; j-- > 0;)
    {
        immutable ulong num = unp[j + m] * cast(ulong) BASE + unp[j + m - 1];
        ulong qhat = num / vTop;
        ulong rhat = num - qhat * vTop;
        while (qhat >= BASE || qhat * vSecond > rhat * BASE + unp[j + m - 2])
        {
            --qhat;
            rhat += vTop;
            if (rhat >= BASE)
                break;
        }

        // Fused multiply-subtract: window -= qhat * v.
        ulong carry = 0;
        uint borrow = 0;
        uint* w = unp + j;
        for (size_t i = 0; i < m; ++i)
        {
            immutable ulong p = qhat * vp[i] + carry;
            carry = p / BASE;
            immutable uint lo = cast(uint)(p - carry * BASE);
            int diff = cast(int) w[i] - cast(int) lo - cast(int) borrow;
            if (diff < 0)
            {
                diff += BASE;
                borrow = 1;
            }
            else
                borrow = 0;
            w[i] = cast(uint) diff;
        }
        long top = cast(long) w[m] - cast(long) carry - borrow;
        if (top < 0)
        {
            // qhat was one too large: add v back once.
            --qhat;
            uint c = 0;
            for (size_t i = 0; i < m; ++i)
            {
                uint s = w[i] + vp[i] + c;
                if (s >= BASE)
                {
                    s -= BASE;
                    c = 1;
                }
                else
                    c = 0;
                w[i] = s;
            }
            top += c;
        }
        w[m] = cast(uint) top;
        quo[j] = cast(uint) qhat;
    }

    q = trim(quo);

    // Remainder: low m limbs of the working array, divided by d.
    uint rem;
    r = divModLimb(trim(un[0 .. m]), cast(uint) d, rem);
}
