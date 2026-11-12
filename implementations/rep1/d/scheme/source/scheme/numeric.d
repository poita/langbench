/**
 * Integer arithmetic on Scheme values.
 *
 * Integers that fit in a machine word are `Kind.integer`; results that
 * overflow transparently become `Kind.bigInteger` and shrink back again when
 * they fit.
 */
module scheme.numeric;

import core.checkedint : adds, muls, subs;
import scheme.bignum : BigNum;
import scheme.value;

/// Turn a `BigNum` into the canonical `Value` (small if it fits).
Value fromBig(BigNum b) pure nothrow @trusted
{
    if (b.fitsLong)
        return Value.fromInt(b.toLong);
    Value v;
    v.kind = Kind.bigInteger;
    v.big = b;
    return v;
}

/// Convert an integer value to a `BigNum`.
BigNum toBig(Value v) pure nothrow @trusted
in (v.isInteger)
{
    return v.kind == Kind.integer ? BigNum.fromLong(v.i) : v.big;
}

/// a + b
Value add(Value a, Value b) pure nothrow @trusted
{
    if (a.kind == Kind.integer && b.kind == Kind.integer)
    {
        bool ov;
        long r = adds(a.i, b.i, ov);
        if (!ov)
            return Value.fromInt(r);
    }
    return fromBig(toBig(a).plus(toBig(b)));
}

/// a - b
Value sub(Value a, Value b) pure nothrow @trusted
{
    if (a.kind == Kind.integer && b.kind == Kind.integer)
    {
        bool ov;
        long r = subs(a.i, b.i, ov);
        if (!ov)
            return Value.fromInt(r);
    }
    return fromBig(toBig(a).minus(toBig(b)));
}

/// a * b
Value mul(Value a, Value b) pure nothrow @trusted
{
    if (a.kind == Kind.integer && b.kind == Kind.integer)
    {
        bool ov;
        long r = muls(a.i, b.i, ov);
        if (!ov)
            return Value.fromInt(r);
    }
    return fromBig(toBig(a).times(toBig(b)));
}

/// Is the integer zero?
bool isZero(Value a) pure nothrow @nogc @trusted
{
    return a.kind == Kind.integer && a.i == 0;
}

/// Quotient truncating toward zero. `b` must not be zero.
Value quotient(Value a, Value b) pure nothrow @trusted
{
    if (a.kind == Kind.integer && b.kind == Kind.integer && b.i != -1)
        return Value.fromInt(a.i / b.i);
    BigNum r;
    return fromBig(toBig(a).divRem(toBig(b), r));
}

/// Remainder with the sign of `a`. `b` must not be zero.
Value remainder(Value a, Value b) pure nothrow @trusted
{
    if (a.kind == Kind.integer && b.kind == Kind.integer)
        return Value.fromInt(b.i == -1 ? 0 : a.i % b.i);
    BigNum r;
    toBig(a).divRem(toBig(b), r);
    return fromBig(r);
}

/// Three-way comparison of two integers.
int compare(Value a, Value b) pure nothrow @trusted
{
    if (a.kind == Kind.integer && b.kind == Kind.integer)
        return a.i < b.i ? -1 : (a.i > b.i ? 1 : 0);
    return toBig(a).compare(toBig(b));
}

/// Decimal representation of an integer.
string integerToString(Value v) pure nothrow @trusted
{
    if (v.kind == Kind.integer)
    {
        // Fast path avoiding std.conv for small values.
        char[20] buf;
        size_t pos = buf.length;
        ulong m = v.i < 0 ? 0UL - cast(ulong) v.i : cast(ulong) v.i;
        do
        {
            buf[--pos] = cast(char)('0' + m % 10);
            m /= 10;
        }
        while (m != 0);
        if (v.i < 0)
            buf[--pos] = '-';
        return buf[pos .. $].idup;
    }
    return v.big.toString();
}

unittest
{
    auto i = Value.fromInt(long.max);
    auto one = Value.fromInt(1);
    auto big = add(i, one);
    assert(big.kind == Kind.bigInteger);
    assert(integerToString(big) == "9223372036854775808");
    auto back = sub(big, one);
    assert(back.kind == Kind.integer && back.i == long.max);
    assert(integerToString(mul(Value.fromInt(long.min), Value.fromInt(-1))) == "9223372036854775808");
    assert(integerToString(Value.fromInt(long.min)) == "-9223372036854775808");
    assert(integerToString(Value.fromInt(0)) == "0");
    assert(integerToString(Value.fromInt(-42)) == "-42");
}

unittest
{
    auto m = Value.fromInt(-7), t = Value.fromInt(2);
    assert(quotient(m, t).i == -3);
    assert(remainder(m, t).i == -1);
    assert(quotient(Value.fromInt(7), Value.fromInt(-2)).i == -3);
    assert(remainder(Value.fromInt(7), Value.fromInt(-2)).i == 1);
    // long.min / -1 overflows a machine word
    auto q = quotient(Value.fromInt(long.min), Value.fromInt(-1));
    assert(integerToString(q) == "9223372036854775808");
    assert(remainder(Value.fromInt(long.min), Value.fromInt(-1)).i == 0);
    assert(compare(q, Value.fromInt(long.max)) > 0);
}
