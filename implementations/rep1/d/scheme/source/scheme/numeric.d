/// Integer arithmetic on `Value`s: fixnum fast paths with promotion to bignums.
module scheme.numeric;

import core.checkedint : adds, subs, muls;
import scheme.bignum;
import scheme.value;

/// Convert an integer value to a `BigInt`.
BigInt toBig(Value v)
{
    return v.tag == Tag.fixnum ? BigInt.fromLong(v.i) : *v.bigObj;
}

/// Canonical value for a `BigInt`: a fixnum whenever it fits.
Value normalize(BigInt b)
{
    long x;
    if (b.toLong(x))
        return Value.fixnum(x);
    return Value.bigint(b);
}

/// `a + b`.
Value add(Value a, Value b)
{
    if (a.tag == Tag.fixnum && b.tag == Tag.fixnum)
    {
        bool o;
        long r = adds(a.i, b.i, o);
        if (!o)
            return Value.fixnum(r);
    }
    return normalize(BigInt.add(toBig(a), toBig(b)));
}

/// `a - b`.
Value sub(Value a, Value b)
{
    if (a.tag == Tag.fixnum && b.tag == Tag.fixnum)
    {
        bool o;
        long r = subs(a.i, b.i, o);
        if (!o)
            return Value.fixnum(r);
    }
    return normalize(BigInt.sub(toBig(a), toBig(b)));
}

/// `a * b`.
Value mul(Value a, Value b)
{
    if (a.tag == Tag.fixnum && b.tag == Tag.fixnum)
    {
        bool o;
        long r = muls(a.i, b.i, o);
        if (!o)
            return Value.fixnum(r);
    }
    return normalize(BigInt.mul(toBig(a), toBig(b)));
}

/// Three-way numeric comparison.
int compare(Value a, Value b)
{
    if (a.tag == Tag.fixnum && b.tag == Tag.fixnum)
        return a.i < b.i ? -1 : (a.i > b.i ? 1 : 0);
    return BigInt.compare(toBig(a), toBig(b));
}

/// Truncating quotient. `b` must be a non-zero integer.
Value quotient(Value a, Value b)
{
    if (a.tag == Tag.fixnum && b.tag == Tag.fixnum)
    {
        if (b.i == -1)
            return sub(Value.fixnum(0), a);
        return Value.fixnum(a.i / b.i);
    }
    BigInt q, r;
    BigInt.divMod(toBig(a), toBig(b), q, r);
    return normalize(q);
}

/// Remainder with the sign of `a`. `b` must be a non-zero integer.
Value remainder(Value a, Value b)
{
    if (a.tag == Tag.fixnum && b.tag == Tag.fixnum)
    {
        if (b.i == -1)
            return Value.fixnum(0);
        return Value.fixnum(a.i % b.i);
    }
    BigInt q, r;
    BigInt.divMod(toBig(a), toBig(b), q, r);
    return normalize(r);
}

/// True iff `v` is an integer equal to zero.
bool isZero(Value v)
{
    return v.tag == Tag.fixnum && v.i == 0;
}

/// Decimal text of an integer value.
string toDecimal(Value v)
{
    if (v.tag == Tag.fixnum)
    {
        char[20] buf;
        size_t p = buf.length;
        bool neg = v.i < 0;
        ulong m = neg ? -cast(ulong) v.i : cast(ulong) v.i;
        do
        {
            buf[--p] = cast(char)('0' + m % 10);
            m /= 10;
        }
        while (m);
        if (neg)
            buf[--p] = '-';
        return buf[p .. $].idup;
    }
    return v.bigObj.toDecimal();
}
