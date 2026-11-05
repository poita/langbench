/// Hand-written arbitrary-precision signed integers.
///
/// A `BigInt` is a sign plus a little-endian magnitude of 32-bit limbs with no
/// high zero limbs; zero has an empty magnitude and is never negative. All
/// limb arithmetic uses 64-bit intermediates. Multiplication is schoolbook,
/// division is short division for one-limb divisors and Knuth's Algorithm D
/// otherwise, and decimal conversion works in groups of nine digits.
module scheme.bignum;

import core.bitop : bsr;

/// A signed arbitrary-precision integer. Values are immutable by convention:
/// operations return new values and never modify their operands' limbs.
struct BigInt
{
    /// True for negative values (never true for zero).
    bool neg;
    /// Little-endian limbs, no high zero limbs.
    uint[] mag;

    /// True iff the value is zero.
    bool isZero() const pure nothrow @safe @nogc { return mag.length == 0; }

    /// Build a `BigInt` from a machine integer.
    static BigInt fromLong(long v) pure nothrow @safe
    {
        BigInt r;
        r.neg = v < 0;
        ulong m = r.neg ? -cast(ulong) v : cast(ulong) v;
        if (m != 0)
        {
            if (m >> 32)
                r.mag = [cast(uint) m, cast(uint)(m >> 32)];
            else
                r.mag = [cast(uint) m];
        }
        return r;
    }

    /// Store the value in `r` and return true iff it fits in a `long`.
    bool toLong(out long r) const pure nothrow @safe @nogc
    {
        if (mag.length > 2)
            return false;
        ulong m = 0;
        if (mag.length > 0)
            m = mag[0];
        if (mag.length > 1)
            m |= cast(ulong) mag[1] << 32;
        if (neg)
        {
            if (m > (cast(ulong) 1 << 63))
                return false;
            r = cast(long)(-m);
            return true;
        }
        if (m > cast(ulong) long.max)
            return false;
        r = cast(long) m;
        return true;
    }

    /// Parse a run of ASCII decimal digits (no sign) into a value, using
    /// multiply-by-10^9-and-add on nine-digit chunks.
    static BigInt parseDecimal(const(char)[] digits, bool negative) pure nothrow
    {
        auto limbs = new uint[digits.length / 9 + 2];
        size_t n = 0;
        size_t first = digits.length % 9;
        if (first == 0)
            first = 9;
        size_t pos = 0;
        size_t chunk = first;
        while (pos < digits.length)
        {
            ulong c = 0;
            foreach (ch; digits[pos .. pos + chunk])
                c = c * 10 + (ch - '0');
            pos += chunk;
            chunk = 9;
            ulong carry = c;
            foreach (i; 0 .. n)
            {
                ulong t = cast(ulong) limbs[i] * 1_000_000_000UL + carry;
                limbs[i] = cast(uint) t;
                carry = t >> 32;
            }
            if (carry)
                limbs[n++] = cast(uint) carry;
        }
        return make(negative, limbs[0 .. n]);
    }

    /// Decimal representation, with a `-` prefix when negative.
    string toDecimal() const pure nothrow
    {
        if (isZero)
            return "0";
        auto work = mag.dup;
        size_t n = work.length;
        // Each pass produces nine decimal digits (one base-10^9 group).
        auto groups = new uint[n * 32 / 29 + 2];
        size_t g = 0;
        while (n > 0)
        {
            ulong rem = 0;
            for (size_t i = n; i-- > 0;)
            {
                ulong cur = (rem << 32) | work[i];
                work[i] = cast(uint)(cur / 1_000_000_000UL);
                rem = cur % 1_000_000_000UL;
            }
            groups[g++] = cast(uint) rem;
            while (n > 0 && work[n - 1] == 0)
                --n;
        }
        auto buf = new char[g * 9 + 1];
        size_t p = 0;
        if (neg)
            buf[p++] = '-';
        // top group unpadded
        {
            char[10] tmp;
            size_t t = tmp.length;
            uint v = groups[g - 1];
            do
            {
                tmp[--t] = cast(char)('0' + v % 10);
                v /= 10;
            }
            while (v);
            buf[p .. p + tmp.length - t] = tmp[t .. $];
            p += tmp.length - t;
        }
        for (size_t i = g - 1; i-- > 0;)
        {
            uint v = groups[i];
            foreach_reverse (k; 0 .. 9)
            {
                buf[p + k] = cast(char)('0' + v % 10);
                v /= 10;
            }
            p += 9;
        }
        return cast(string) buf[0 .. p];
    }

    /// Three-way comparison: negative, zero or positive.
    static int compare(in BigInt a, in BigInt b) pure nothrow @safe @nogc
    {
        if (a.neg != b.neg)
            return a.neg ? -1 : 1;
        int c = cmpMag(a.mag, b.mag);
        return a.neg ? -c : c;
    }

    /// The additive inverse.
    BigInt negated() const pure nothrow @safe
    {
        return make(!neg, mag.dup);
    }

    /// Sum.
    static BigInt add(in BigInt a, in BigInt b) pure nothrow @safe
    {
        if (a.neg == b.neg)
            return make(a.neg, addMag(a.mag, b.mag));
        int c = cmpMag(a.mag, b.mag);
        if (c == 0)
            return BigInt.init;
        if (c > 0)
            return make(a.neg, subMag(a.mag, b.mag));
        return make(b.neg, subMag(b.mag, a.mag));
    }

    /// Difference `a - b`.
    static BigInt sub(in BigInt a, in BigInt b) pure nothrow @trusted
    {
        BigInt nb;
        nb.neg = !b.neg && !b.isZero;
        nb.mag = cast(uint[]) b.mag; // shared, never written
        return add(a, nb);
    }

    /// Product (schoolbook).
    static BigInt mul(in BigInt a, in BigInt b) pure nothrow @safe
    {
        if (a.isZero || b.isZero)
            return BigInt.init;
        return make(a.neg != b.neg, mulMag(a.mag, b.mag));
    }

    /// Truncating division: `q = trunc(a / b)`, `r = a - b*q` (sign of `a`).
    /// `b` must not be zero.
    static void divMod(in BigInt a, in BigInt b, out BigInt q, out BigInt r) pure nothrow @trusted
    {
        assert(!b.isZero);
        if (cmpMag(a.mag, b.mag) < 0)
        {
            q = BigInt.init;
            r.neg = a.neg;
            r.mag = cast(uint[]) a.mag;
            return;
        }
        uint[] qm, rm;
        if (b.mag.length == 1)
        {
            qm = new uint[a.mag.length];
            ulong d = b.mag[0];
            ulong rem = 0;
            for (size_t i = a.mag.length; i-- > 0;)
            {
                ulong cur = (rem << 32) | a.mag[i];
                qm[i] = cast(uint)(cur / d);
                rem = cur % d;
            }
            rm = rem ? [cast(uint) rem] : null;
        }
        else
            knuthD(a.mag, b.mag, qm, rm);
        q = make(a.neg != b.neg, qm);
        r = make(a.neg, rm);
    }

private:
    /// Normalise limbs and sign into a canonical value.
    static BigInt make(bool neg, uint[] mag) pure nothrow @safe
    {
        size_t n = mag.length;
        while (n > 0 && mag[n - 1] == 0)
            --n;
        BigInt r;
        r.mag = mag[0 .. n];
        r.neg = neg && n > 0;
        return r;
    }

    static int cmpMag(in uint[] a, in uint[] b) pure nothrow @safe @nogc
    {
        if (a.length != b.length)
            return a.length < b.length ? -1 : 1;
        for (size_t i = a.length; i-- > 0;)
            if (a[i] != b[i])
                return a[i] < b[i] ? -1 : 1;
        return 0;
    }

    static uint[] addMag(in uint[] x, in uint[] y) pure nothrow @safe
    {
        const(uint)[] a = x, b = y;
        if (a.length < b.length)
        {
            auto t = a;
            a = b;
            b = t;
        }
        auto r = new uint[a.length + 1];
        ulong carry = 0;
        foreach (i; 0 .. a.length)
        {
            ulong t = cast(ulong) a[i] + (i < b.length ? b[i] : 0) + carry;
            r[i] = cast(uint) t;
            carry = t >> 32;
        }
        r[a.length] = cast(uint) carry;
        return r;
    }

    /// `a - b`, requires `|a| >= |b|`.
    static uint[] subMag(in uint[] a, in uint[] b) pure nothrow @safe
    {
        auto r = new uint[a.length];
        long borrow = 0;
        foreach (i; 0 .. a.length)
        {
            long t = cast(long) a[i] - (i < b.length ? b[i] : 0) - borrow;
            borrow = t < 0 ? 1 : 0;
            r[i] = cast(uint) t;
        }
        return r;
    }

    static uint[] mulMag(in uint[] a, in uint[] b) pure nothrow @safe
    {
        auto r = new uint[a.length + b.length];
        foreach (i; 0 .. a.length)
        {
            ulong ai = a[i];
            if (ai == 0)
                continue;
            ulong carry = 0;
            foreach (j; 0 .. b.length)
            {
                ulong t = ai * b[j] + r[i + j] + carry;
                r[i + j] = cast(uint) t;
                carry = t >> 32;
            }
            r[i + b.length] = cast(uint) carry;
        }
        return r;
    }

    /// Knuth's Algorithm D; `v.length >= 2`, `u >= v`.
    static void knuthD(in uint[] u, in uint[] v, out uint[] q, out uint[] r) pure nothrow @safe
    {
        immutable size_t m = u.length, n = v.length;
        immutable int s = 31 - bsr(v[n - 1]);
        auto vn = new uint[n];
        auto un = new uint[m + 1];
        foreach_reverse (i; 1 .. n)
            vn[i] = (v[i] << s) | cast(uint)(cast(ulong) v[i - 1] >> (32 - s));
        vn[0] = v[0] << s;
        un[m] = cast(uint)(cast(ulong) u[m - 1] >> (32 - s));
        foreach_reverse (i; 1 .. m)
            un[i] = (u[i] << s) | cast(uint)(cast(ulong) u[i - 1] >> (32 - s));
        un[0] = u[0] << s;

        q = new uint[m - n + 1];
        enum ulong B = 1UL << 32;
        for (size_t j = m - n + 1; j-- > 0;)
        {
            ulong num = (cast(ulong) un[j + n] << 32) | un[j + n - 1];
            ulong qhat = num / vn[n - 1];
            ulong rhat = num - qhat * vn[n - 1];
            while (qhat >= B || qhat * vn[n - 2] > ((rhat << 32) | un[j + n - 2]))
            {
                --qhat;
                rhat += vn[n - 1];
                if (rhat >= B)
                    break;
            }
            long k = 0;
            long t;
            foreach (i; 0 .. n)
            {
                ulong p = qhat * vn[i];
                t = cast(long) un[i + j] - k - cast(long)(p & 0xFFFF_FFFF);
                un[i + j] = cast(uint) t;
                k = cast(long)(p >> 32) - (t >> 32);
            }
            t = cast(long) un[j + n] - k;
            un[j + n] = cast(uint) t;
            q[j] = cast(uint) qhat;
            if (t < 0)
            {
                --q[j];
                k = 0;
                foreach (i; 0 .. n)
                {
                    t = cast(long) un[i + j] + vn[i] + k;
                    un[i + j] = cast(uint) t;
                    k = t >> 32;
                }
                un[j + n] += cast(uint) k;
            }
        }
        r = new uint[n];
        foreach (i; 0 .. n - 1)
            r[i] = (un[i] >> s) | cast(uint)(cast(ulong) un[i + 1] << (32 - s));
        r[n - 1] = un[n - 1] >> s;
    }
}
