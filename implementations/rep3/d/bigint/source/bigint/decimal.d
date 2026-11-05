/**
 * Linear-time conversion between decimal text and base-10^9 magnitudes.
 */
module bigint.decimal;

import bigint.magnitude;

/**
 * Parses a string of ASCII digits (no sign) into a magnitude.
 *
 * Leading zeros are allowed; an all-zero string gives the empty magnitude.
 * Digits are consumed nine at a time from the right end.
 *
 * Throws: `Exception` if `digits` is empty or holds a non-digit.
 */
Limbs parseMagnitude(scope const(char)[] digits) pure @trusted
{
    if (digits.length == 0)
        throw new Exception("bigint: empty digit string");
    size_t start = 0;
    while (start < digits.length && digits[start] == '0')
        ++start;
    // Validate the skipped zeros trivially; validate the rest while converting.
    immutable size_t len = digits.length - start;
    if (len == 0)
        return null;
    auto r = new uint[(len + LIMB_DIGITS - 1) / LIMB_DIGITS];
    const(char)* p = digits.ptr + digits.length;
    size_t remaining = len;
    foreach (ref limb; r)
    {
        immutable size_t take = remaining < LIMB_DIGITS ? remaining : LIMB_DIGITS;
        uint acc = 0;
        const(char)* q = p - take;
        foreach (k; 0 .. take)
        {
            immutable uint dgt = cast(uint) q[k] - '0';
            if (dgt > 9)
                throw new Exception("bigint: invalid digit in input");
            acc = acc * 10 + dgt;
        }
        limb = acc;
        p = q;
        remaining -= take;
    }
    return trim(r);
}

/// Number of decimal digits in the canonical form of `mag` (1 for zero).
size_t decimalLength(scope const(uint)[] mag) pure nothrow @nogc @safe
{
    if (mag.length == 0)
        return 1;
    size_t digits = (mag.length - 1) * LIMB_DIGITS;
    uint top = mag[$ - 1];
    while (top != 0)
    {
        ++digits;
        top /= 10;
    }
    return digits;
}

/**
 * Writes the canonical decimal form of `mag` (no sign) into `buf`, which must
 * hold at least `decimalLength(mag)` characters.
 *
 * Returns: the number of characters written.
 */
size_t formatMagnitude(scope const(uint)[] mag, scope char[] buf) pure nothrow @trusted
{
    if (mag.length == 0)
    {
        buf[0] = '0';
        return 1;
    }
    immutable size_t total = decimalLength(mag);
    assert(buf.length >= total);
    char* out_ = buf.ptr;
    size_t pos = 0;
    // Top limb without padding.
    {
        uint top = mag[$ - 1];
        size_t nd = 0;
        for (uint t = top; t != 0; t /= 10)
            ++nd;
        for (size_t k = nd; k-- > 0;)
        {
            out_[pos + k] = cast(char)('0' + top % 10);
            top /= 10;
        }
        pos += nd;
    }
    for (size_t i = mag.length - 1; i-- > 0;)
    {
        uint limb = mag[i];
        for (size_t k = LIMB_DIGITS; k-- > 0;)
        {
            out_[pos + k] = cast(char)('0' + limb % 10);
            limb /= 10;
        }
        pos += LIMB_DIGITS;
    }
    return pos;
}
