/**
 * Low-level unsigned ("magnitude") arithmetic on little-endian arrays of
 * base-10^9 limbs.
 *
 * A magnitude is a `uint[]` whose elements are each in `[0, 10^9)`, least
 * significant limb first, with no most-significant zero limbs. Zero is the
 * empty array. All functions here return freshly allocated arrays and never
 * modify their (const) arguments, so magnitudes can be shared freely.
 *
 * Quadratic schoolbook algorithms are used throughout: linear add / subtract /
 * compare, schoolbook multiplication, short division and Knuth's Algorithm D.
 */
module bigint.limbs;

/// The limb base, 10^9. Largest power of ten whose limb products fit in 64 bits.
enum uint base = 1_000_000_000;
/// Number of decimal digits per limb.
enum size_t limbDigits = 9;

private enum ulong B = base;

/// Strips most-significant zero limbs (returns a slice of the same array).
inout(uint)[] trim(inout(uint)[] a) pure nothrow @nogc @safe
{
    size_t n = a.length;
    while (n > 0 && a[n - 1] == 0)
        --n;
    return a[0 .. n];
}

/// Three-way comparison of two trimmed magnitudes: -1, 0 or 1.
int cmpMag(const(uint)[] a, const(uint)[] b) pure nothrow @nogc @safe
{
    if (a.length != b.length)
        return a.length < b.length ? -1 : 1;
    for (size_t i = a.length; i-- > 0;)
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    return 0;
}

/// Returns `a + b`.
uint[] addMag(const(uint)[] a, const(uint)[] b) pure nothrow @safe
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
        uint s = a[i] + b[i] + carry; // < 2*10^9 fits in 32 bits
        if (s >= base)
        {
            s -= base;
            carry = 1;
        }
        else
            carry = 0;
        r[i] = s;
    }
    for (; i < a.length; ++i)
    {
        uint s = a[i] + carry;
        if (s >= base)
        {
            s -= base;
            carry = 1;
        }
        else
            carry = 0;
        r[i] = s;
    }
    r[i] = carry;
    return trim(r);
}

/// Returns `a - b`. Requires `a >= b`.
uint[] subMag(const(uint)[] a, const(uint)[] b) pure nothrow @safe
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
            d += base;
            borrow = 1;
        }
        else
            borrow = 0;
        r[i] = d;
    }
    for (; i < a.length; ++i)
    {
        int d = cast(int) a[i] - cast(int) borrow;
        if (d < 0)
        {
            d += base;
            borrow = 1;
        }
        else
            borrow = 0;
        r[i] = d;
    }
    return trim(r);
}

/// Returns `a * b` using schoolbook multiplication.
uint[] mulMag(const(uint)[] a, const(uint)[] b) pure nothrow @trusted
{
    if (a.length == 0 || b.length == 0)
        return null;
    // Rows over the shorter operand, columns over the longer one.
    if (a.length > b.length)
    {
        auto t = a;
        a = b;
        b = t;
    }
    auto r = new uint[a.length + b.length];
    immutable m = b.length;
    const(uint)* bp = b.ptr;
    foreach (i; 0 .. a.length)
    {
        immutable ulong ai = a[i];
        if (ai == 0)
            continue;
        uint* rp = r.ptr + i;
        ulong carry = 0;
        foreach (j; 0 .. m)
        {
            immutable ulong t = rp[j] + ai * bp[j] + carry;
            carry = t / B;
            rp[j] = cast(uint)(t - carry * B);
        }
        rp[m] = cast(uint) carry; // slot above the row is still zero
    }
    return trim(r);
}

/// Result of a magnitude division.
struct DivModMag
{
    uint[] quotient;  /// `a / b`
    uint[] remainder; /// `a % b`
}

/**
 * Divides a magnitude by a single limb `d` (`0 < d < 10^9`), returning the
 * quotient and storing the remainder in `rem`.
 */
uint[] divShort(const(uint)[] a, uint d, out uint rem) pure nothrow @safe
in (d != 0 && d < base)
{
    auto q = new uint[a.length];
    ulong r = 0;
    for (size_t i = a.length; i-- > 0;)
    {
        immutable ulong cur = r * B + a[i];
        immutable ulong qd = cur / d;
        q[i] = cast(uint) qd;
        r = cur - qd * d;
    }
    rem = cast(uint) r;
    return trim(q);
}

/**
 * Divides `a` by `b` (`b` non-zero), returning quotient and remainder.
 *
 * Uses short division for one-limb divisors and Knuth's Algorithm D otherwise.
 */
DivModMag divModMag(const(uint)[] a, const(uint)[] b) pure nothrow @trusted
in (b.length > 0, "division by zero")
{
    if (cmpMag(a, b) < 0)
        return DivModMag(null, a.dup);
    if (b.length == 1)
    {
        uint rem;
        auto q = divShort(a, b[0], rem);
        return DivModMag(q, rem == 0 ? null : [rem]);
    }

    immutable size_t n = a.length, m = b.length;
    immutable uint d = cast(uint)(B / (b[m - 1] + 1UL));

    // Normalise: u = a * d (n + 1 limbs), v = b * d (m limbs).
    auto u = new uint[n + 1];
    auto v = new uint[m];
    {
        ulong carry = 0;
        foreach (i; 0 .. n)
        {
            immutable ulong t = a[i] * cast(ulong) d + carry;
            carry = t / B;
            u[i] = cast(uint)(t - carry * B);
        }
        u[n] = cast(uint) carry;
        carry = 0;
        foreach (i; 0 .. m)
        {
            immutable ulong t = b[i] * cast(ulong) d + carry;
            carry = t / B;
            v[i] = cast(uint)(t - carry * B);
        }
        // carry == 0 because v's top limb stays below 10^9
    }

    auto q = new uint[n - m + 1];
    immutable ulong vTop = v[m - 1], vNext = v[m - 2];
    uint* up = u.ptr;
    const(uint)* vp = v.ptr;

    for (size_t j = n - m + 1; j-- > 0;)
    {
        uint* w = up + j; // window of m + 1 limbs
        immutable ulong num = w[m] * B + w[m - 1];
        ulong qhat = num / vTop;
        ulong rhat = num - qhat * vTop;
        while (qhat >= B || qhat * vNext > rhat * B + w[m - 2])
        {
            --qhat;
            rhat += vTop;
            if (rhat >= B)
                break;
        }

        // Fused multiply-subtract: w -= qhat * v.
        ulong carry = 0;
        uint borrow = 0;
        foreach (i; 0 .. m)
        {
            immutable ulong p = qhat * vp[i] + carry;
            carry = p / B;
            immutable long diff = cast(long) w[i] - cast(long)(p - carry * B) - borrow;
            if (diff < 0)
            {
                w[i] = cast(uint)(diff + B);
                borrow = 1;
            }
            else
            {
                w[i] = cast(uint) diff;
                borrow = 0;
            }
        }
        immutable long top = cast(long) w[m] - cast(long) carry - borrow;
        if (top < 0)
        {
            // qhat was one too large: add v back once.
            --qhat;
            uint c = 0;
            foreach (i; 0 .. m)
            {
                uint s = w[i] + vp[i] + c;
                if (s >= base)
                {
                    s -= base;
                    c = 1;
                }
                else
                    c = 0;
                w[i] = s;
            }
            w[m] = 0; // top + B + c wraps to zero
        }
        else
            w[m] = cast(uint) top;
        q[j] = cast(uint) qhat;
    }

    // Remainder = low m limbs of u, divided by d.
    uint rem;
    auto r = divShort(u[0 .. m].trim, d, rem);
    return DivModMag(trim(q), r);
}

/**
 * Parses the decimal digits `digits` (ASCII `0`-`9` only, any number of
 * leading zeros) into a magnitude. Linear time. Returns `false` if a
 * non-digit is found.
 */
bool parseMag(const(char)[] digits, out uint[] result) pure nothrow @safe
{
    size_t start = 0;
    while (start < digits.length && digits[start] == '0')
        ++start;
    digits = digits[start .. $];
    foreach (c; digits)
        if (c < '0' || c > '9')
            return false;
    immutable n = (digits.length + limbDigits - 1) / limbDigits;
    auto r = new uint[n];
    size_t end = digits.length;
    foreach (i; 0 .. n)
    {
        immutable begin = end >= limbDigits ? end - limbDigits : 0;
        uint v = 0;
        foreach (c; digits[begin .. end])
            v = v * 10 + (c - '0');
        r[i] = v;
        end = begin;
    }
    result = r;
    return true;
}

/**
 * Writes the decimal form of a magnitude (`0` for zero, no padding on the top
 * limb, nine digits for every other limb) to the output range `sink`.
 */
void putMag(Sink)(ref Sink sink, const(uint)[] a)
{
    import std.range.primitives : put;

    if (a.length == 0)
    {
        put(sink, '0');
        return;
    }
    char[limbDigits] buf = void;
    // Top limb, unpadded.
    {
        uint v = a[$ - 1];
        size_t p = limbDigits;
        do
        {
            buf[--p] = cast(char)('0' + v % 10);
            v /= 10;
        }
        while (v);
        put(sink, buf[p .. $]);
    }
    for (size_t i = a.length - 1; i-- > 0;)
    {
        uint v = a[i];
        foreach_reverse (k; 0 .. limbDigits)
        {
            buf[k] = cast(char)('0' + v % 10);
            v /= 10;
        }
        put(sink, buf[]);
    }
}
