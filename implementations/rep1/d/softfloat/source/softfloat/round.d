/**
 * The single rounding routine shared by every operation.
 */
module softfloat.round;

import core.bitop : bsr;
import softfloat.bits;

@safe pure nothrow @nogc:

/**
 * Rounds `m * 2^e` (plus a sticky residue) to binary32, ties to even, and
 * packs the result.
 *
 * Params:
 *   negative = sign of the result
 *   m        = nonzero integer significand
 *   e        = exponent of the least significant bit of `m`
 *   sticky   = true if the exact value is slightly larger than `m * 2^e`
 *              (strictly less than one unit of `m`'s lowest bit). When set,
 *              `m` must carry at least one bit more than the target grid.
 *
 * Rounding is performed exactly once, directly on the final grid (normal or
 * denormal), so there is no double rounding. Overflow yields infinity;
 * rounding up out of the denormal range yields 0x00800000 naturally.
 */
uint roundPack(bool negative, ulong m, int e, bool sticky)
{
    immutable uint sign = negative ? signMask : 0;
    if (m == 0)
        return sign;

    immutable int lead = bsr(m);
    // Exponent of the lowest kept bit on the binary32 grid.
    immutable int grid = lead + e - 23 > minExponent ? lead + e - 23 : minExponent;
    immutable int shift = grid - e;

    ulong q;
    bool roundBit = false;
    bool rest = sticky;
    if (shift <= 0)
    {
        q = m << -shift;
    }
    else if (shift > 64)
    {
        q = 0;
        rest = true;
    }
    else
    {
        q = shift == 64 ? 0 : m >> shift;
        roundBit = ((m >> (shift - 1)) & 1) != 0;
        rest = rest || (m & ((1UL << (shift - 1)) - 1)) != 0;
    }

    if (roundBit && (rest || (q & 1)))
        ++q;

    int g = grid;
    if (q == (1UL << 24))
    {
        q = 1UL << 23;
        ++g;
    }

    // For denormals g == -149 so biased == 1 and the sum below is just q.
    immutable int biased = g + 150;
    if (biased >= 255)
        return sign | positiveInfinity;
    return sign | ((cast(uint)(biased - 1) << 23) + cast(uint) q);
}
