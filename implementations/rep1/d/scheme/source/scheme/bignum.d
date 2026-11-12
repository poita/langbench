/**
 * Arbitrary-precision signed integers, written from scratch.
 *
 * Numbers are stored as sign and magnitude; the magnitude is a little-endian
 * array of 32-bit limbs with no leading zero limbs (zero is the empty array).
 * The algorithms are the classical ones: schoolbook multiplication, Knuth's
 * Algorithm D for division and repeated division by 10^9 for decimal output.
 *
 * `BigNum` values are immutable once constructed.
 */
module scheme.bignum;

private alias Limbs = const(uint)[];

private enum ulong base = 1UL << 32;

/// An immutable arbitrary-precision integer.
final class BigNum
{
    private bool neg;
    private uint[] mag;

    private this(bool neg, uint[] mag) pure nothrow @safe
    {
        size_t n = mag.length;
        while (n > 0 && mag[n - 1] == 0)
            --n;
        this.mag = mag[0 .. n];
        this.neg = neg && n > 0;
    }

    /// Construct from a machine integer.
    static BigNum fromLong(long v) pure nothrow @safe
    {
        ulong m = v < 0 ? 0UL - cast(ulong) v : cast(ulong) v;
        return new BigNum(v < 0, [cast(uint) m, cast(uint)(m >> 32)]);
    }

    /// Parse a string of ASCII decimal digits (no sign) and apply `negative`.
    static BigNum parse(const(char)[] digits, bool negative = false) pure nothrow @safe
    {
        uint[] m;
        size_t i = 0;
        while (i < digits.length)
        {
            size_t take = digits.length - i;
            if (take > 9)
                take = 9;
            uint chunk = 0, scale = 1;
            foreach (c; digits[i .. i + take])
            {
                assert(c >= '0' && c <= '9');
                chunk = chunk * 10 + (c - '0');
                scale *= 10;
            }
            // m = m * scale + chunk, in place
            ulong carry = chunk;
            foreach (ref limb; m)
            {
                ulong t = cast(ulong) limb * scale + carry;
                limb = cast(uint) t;
                carry = t >> 32;
            }
            if (carry != 0)
                m ~= cast(uint) carry;
            i += take;
        }
        return new BigNum(negative, m);
    }

    /// True for zero.
    @property bool isZero() const pure nothrow @safe @nogc
    {
        return mag.length == 0;
    }

    /// True for negative numbers.
    @property bool isNegative() const pure nothrow @safe @nogc
    {
        return neg;
    }

    /// Does the value fit in a `long`?
    @property bool fitsLong() const pure nothrow @safe @nogc
    {
        if (mag.length > 2)
            return false;
        ulong m = magnitudeAsUlong;
        return neg ? m <= (1UL << 63) : m < (1UL << 63);
    }

    private ulong magnitudeAsUlong() const pure nothrow @safe @nogc
    {
        ulong m = 0;
        if (mag.length > 0)
            m = mag[0];
        if (mag.length > 1)
            m |= cast(ulong) mag[1] << 32;
        return m;
    }

    /// The value as a `long`; only meaningful when `fitsLong`.
    long toLong() const pure nothrow @safe @nogc
    {
        ulong m = magnitudeAsUlong;
        return neg ? cast(long)(0UL - m) : cast(long) m;
    }

    /// -this
    BigNum negated() const pure nothrow @safe
    {
        return new BigNum(!neg, mag.dup);
    }

    /// this + rhs
    BigNum plus(const BigNum rhs) const pure nothrow @safe
    {
        if (neg == rhs.neg)
            return new BigNum(neg, magAdd(mag, rhs.mag));
        int c = magCmp(mag, rhs.mag);
        if (c == 0)
            return new BigNum(false, null);
        if (c > 0)
            return new BigNum(neg, magSub(mag, rhs.mag));
        return new BigNum(rhs.neg, magSub(rhs.mag, mag));
    }

    /// this - rhs
    BigNum minus(const BigNum rhs) const pure nothrow @safe
    {
        if (neg != rhs.neg)
            return new BigNum(neg, magAdd(mag, rhs.mag));
        int c = magCmp(mag, rhs.mag);
        if (c == 0)
            return new BigNum(false, null);
        if (c > 0)
            return new BigNum(neg, magSub(mag, rhs.mag));
        return new BigNum(!neg, magSub(rhs.mag, mag));
    }

    /// this * rhs (schoolbook, O(n*m)).
    BigNum times(const BigNum rhs) const pure nothrow @safe
    {
        if (isZero || rhs.isZero)
            return new BigNum(false, null);
        return new BigNum(neg != rhs.neg, magMul(mag, rhs.mag));
    }

    /**
     * Truncating division: returns the quotient and stores the remainder
     * (which has the sign of `this`) in `remainder`. `rhs` must be non-zero.
     */
    BigNum divRem(const BigNum rhs, out BigNum remainder) const pure nothrow @safe
    in (!rhs.isZero, "division by zero")
    {
        uint[] q, r;
        magDivRem(mag, rhs.mag, q, r);
        remainder = new BigNum(neg, r);
        return new BigNum(neg != rhs.neg, q);
    }

    /// Three-way comparison: negative, zero or positive.
    int compare(const BigNum rhs) const pure nothrow @safe @nogc
    {
        if (neg != rhs.neg)
            return neg ? -1 : 1;
        int c = magCmp(mag, rhs.mag);
        return neg ? -c : c;
    }

    /// Value equality.
    bool equals(const BigNum rhs) const pure nothrow @safe @nogc
    {
        return compare(rhs) == 0;
    }

    /// Decimal representation (O(n^2): repeated division by 10^9).
    override string toString() const pure nothrow @safe
    {
        if (mag.length == 0)
            return "0";
        uint[] work = mag.dup;
        uint[] chunks;
        while (work.length > 0)
        {
            chunks ~= divSmallInPlace(work, 1_000_000_000);
            while (work.length > 0 && work[$ - 1] == 0)
                work = work[0 .. $ - 1];
        }
        char[] s;
        if (neg)
            s ~= '-';
        foreach_reverse (i, chunk; chunks)
        {
            char[9] digits;
            foreach_reverse (j; 0 .. 9)
            {
                digits[j] = cast(char)('0' + chunk % 10);
                chunk /= 10;
            }
            if (i + 1 == chunks.length)
            {
                size_t k = 0;
                while (k < 8 && digits[k] == '0')
                    ++k;
                s ~= digits[k .. $];
            }
            else
                s ~= digits[];
        }
        return s.idup;
    }
}

// ---------------------------------------------------------------------------
// Magnitude arithmetic
// ---------------------------------------------------------------------------

private int magCmp(Limbs a, Limbs b) pure nothrow @safe @nogc
{
    if (a.length != b.length)
        return a.length < b.length ? -1 : 1;
    foreach_reverse (i; 0 .. a.length)
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    return 0;
}

private uint[] magAdd(Limbs a, Limbs b) pure nothrow @safe
{
    if (a.length < b.length)
        return magAdd(b, a);
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

/// a - b, requires a >= b.
private uint[] magSub(Limbs a, Limbs b) pure nothrow @safe
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

private uint[] magMul(Limbs a, Limbs b) pure nothrow @safe
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

/// Divide `m` by `d` in place; returns the remainder. Leaves leading zeros.
private uint divSmallInPlace(uint[] m, uint d) pure nothrow @safe @nogc
{
    ulong rem = 0;
    foreach_reverse (i; 0 .. m.length)
    {
        ulong cur = (rem << 32) | m[i];
        m[i] = cast(uint)(cur / d);
        rem = cur % d;
    }
    return cast(uint) rem;
}

private uint leadingZeros(uint x) pure nothrow @safe @nogc
{
    uint n = 0;
    while ((x & 0x8000_0000) == 0)
    {
        x <<= 1;
        ++n;
    }
    return n;
}

/// Knuth, TAOCP vol. 2, 4.3.1, Algorithm D. `v` must be non-zero.
private void magDivRem(Limbs u, Limbs v, out uint[] quot, out uint[] rem) pure nothrow @safe
{
    if (magCmp(u, v) < 0)
    {
        quot = null;
        rem = u.dup;
        return;
    }
    immutable size_t n = v.length;
    immutable size_t m = u.length;
    if (n == 1)
    {
        quot = u.dup;
        uint r = divSmallInPlace(quot, v[0]);
        rem = [r];
        return;
    }

    // D1: normalise so the top limb of the divisor has its high bit set.
    immutable uint s = leadingZeros(v[n - 1]);
    auto vn = new uint[n];
    auto un = new uint[m + 1];
    if (s == 0)
    {
        vn[] = v[];
        un[0 .. m] = u[];
    }
    else
    {
        foreach_reverse (i; 1 .. n)
            vn[i] = (v[i] << s) | (v[i - 1] >> (32 - s));
        vn[0] = v[0] << s;
        un[m] = u[m - 1] >> (32 - s);
        foreach_reverse (i; 1 .. m)
            un[i] = (u[i] << s) | (u[i - 1] >> (32 - s));
        un[0] = u[0] << s;
    }

    auto q = new uint[m - n + 1];
    // D2..D7
    foreach_reverse (j; 0 .. m - n + 1)
    {
        // D3: estimate the quotient digit.
        ulong num = (cast(ulong) un[j + n] << 32) | un[j + n - 1];
        ulong qhat = num / vn[n - 1];
        ulong rhat = num - qhat * vn[n - 1];
        while (qhat >= base || qhat * vn[n - 2] > ((rhat << 32) | un[j + n - 2]))
        {
            --qhat;
            rhat += vn[n - 1];
            if (rhat >= base)
                break;
        }

        // D4: multiply and subtract.
        long borrow = 0;
        long t;
        foreach (i; 0 .. n)
        {
            ulong p = qhat * vn[i];
            t = cast(long) un[i + j] - borrow - cast(long)(p & 0xFFFF_FFFF);
            un[i + j] = cast(uint) t;
            borrow = cast(long)(p >> 32) - (t >> 32);
        }
        t = cast(long) un[j + n] - borrow;
        un[j + n] = cast(uint) t;

        // D5/D6: if the result was negative, add the divisor back.
        q[j] = cast(uint) qhat;
        if (t < 0)
        {
            --q[j];
            ulong carry = 0;
            foreach (i; 0 .. n)
            {
                ulong sum = cast(ulong) un[i + j] + vn[i] + carry;
                un[i + j] = cast(uint) sum;
                carry = sum >> 32;
            }
            un[j + n] += cast(uint) carry;
        }
    }

    // D8: denormalise the remainder.
    auto r = new uint[n];
    if (s == 0)
        r[] = un[0 .. n];
    else
        foreach (i; 0 .. n)
            r[i] = (un[i] >> s) | (un[i + 1] << (32 - s));
    quot = q;
    rem = r;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest // decimal round trips
{
    foreach (s; ["0", "1", "-1", "4294967296", "-4294967297", "18446744073709551616",
            "123456789012345678901234567890", "-99999999999999999999999999999999999999"])
    {
        bool neg = s[0] == '-';
        auto b = BigNum.parse(neg ? s[1 .. $] : s, neg);
        assert(b.toString() == s, s);
    }
    assert(BigNum.parse("000000000000000000000012", true).toString() == "-12");
    assert(BigNum.parse("0", true).toString() == "0"); // no negative zero
    assert(BigNum.parse("1000000000").toString() == "1000000000");
    assert(BigNum.parse("1000000000000000000").toString() == "1000000000000000000");
}

unittest // machine-word conversion
{
    foreach (v; [0L, 1, -1, long.max, long.min, long.min + 1, 1L << 32, -(1L << 32)])
    {
        auto b = BigNum.fromLong(v);
        assert(b.fitsLong);
        assert(b.toLong == v);
    }
    auto big = BigNum.fromLong(long.max).plus(BigNum.fromLong(1));
    assert(!big.fitsLong);
    assert(big.toString() == "9223372036854775808");
    assert(big.negated().fitsLong);
    assert(big.negated().toLong == long.min);
    assert(!big.negated().minus(BigNum.fromLong(1)).fitsLong);
}

unittest // add, sub, mul against 64-bit arithmetic
{
    long[] vals = [0, 1, -1, 2, -7, 4294967295, 4294967296, -4294967296,
        1_000_000_007, -3_000_000_000, 99_999_999_999, 123_456_789];
    foreach (a; vals)
        foreach (b; vals)
        {
            auto x = BigNum.fromLong(a), y = BigNum.fromLong(b);
            assert(x.plus(y).toLong == a + b);
            assert(x.minus(y).toLong == a - b);
            assert(x.compare(y) == (a < b ? -1 : a > b ? 1 : 0));
            auto prod = x.times(y);
            // values up to ~1e11 * 1e11 overflow long, so check via division
            if (b != 0)
            {
                BigNum r;
                auto q = prod.divRem(y, r);
                assert(q.equals(x) && r.isZero);
            }
        }
}

unittest // factorials and powers
{
    BigNum f = BigNum.fromLong(1);
    foreach (i; 1 .. 31)
        f = f.times(BigNum.fromLong(i));
    assert(f.toString() == "265252859812191058636308480000000");
    BigNum p = BigNum.fromLong(1);
    foreach (i; 0 .. 200)
        p = p.times(BigNum.fromLong(2));
    assert(p.toString() == "1606938044258990275541962092341162602522202993782792835301376");
}

unittest // division: truncation toward zero and the Knuth D paths
{
    auto d = (long a, long b) {
        BigNum r;
        auto q = BigNum.fromLong(a).divRem(BigNum.fromLong(b), r);
        return [q.toLong, r.toLong];
    };
    assert(d(7, 2) == [3, 1]);
    assert(d(-7, 2) == [-3, -1]);
    assert(d(7, -2) == [-3, 1]);
    assert(d(-7, -2) == [3, -1]);
    assert(d(0, 5) == [0, 0]);
    assert(d(5, 100) == [0, 5]);

    // Multi-limb divisors, including the rare "add back" step.
    auto a = BigNum.parse("340282366920938463463374607431768211455"); // 2^128-1
    auto b = BigNum.parse("18446744073709551615"); // 2^64-1
    BigNum r;
    auto q = a.divRem(b, r);
    assert(q.toString() == "18446744073709551617");
    assert(r.isZero);
    // 2^96 / (2^64 + 1) exercises the qhat correction loop
    auto x = BigNum.parse("79228162514264337593543950336");
    auto y = BigNum.parse("18446744073709551617");
    q = x.divRem(y, r);
    assert(q.times(y).plus(r).equals(x));
    assert(r.compare(y) < 0);
}

unittest // randomised identity: a == q*b + r, |r| < |b|
{
    import std.random : Mt19937, uniform;

    auto rng = Mt19937(12345);
    BigNum randomBig(int maxLimbs)
    {
        char[] digits;
        foreach (i; 0 .. uniform(1, maxLimbs * 10, rng))
            digits ~= cast(char)('0' + uniform(0, 10, rng));
        return BigNum.parse(digits, uniform(0, 2, rng) == 1);
    }

    foreach (iter; 0 .. 400)
    {
        auto a = randomBig(12);
        auto b = randomBig(6);
        if (b.isZero)
            continue;
        BigNum r;
        auto q = a.divRem(b, r);
        assert(q.times(b).plus(r).equals(a));
        assert(r.isZero || r.isNegative == a.isNegative);
        BigNum absR = r.isNegative ? r.negated() : r;
        BigNum absB = b.isNegative ? b.negated() : b;
        assert(absR.compare(absB) < 0);
        // parse(toString) round-trips
        auto s = a.toString();
        bool neg = s[0] == '-';
        assert(BigNum.parse(neg ? s[1 .. $] : s, neg).equals(a));
    }
}
