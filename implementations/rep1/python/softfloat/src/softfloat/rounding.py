"""The shared round-and-pack step."""

from __future__ import annotations

from .bits import INF, MIN_EXP


def round_pack(sign: int, m: int, e: int, sticky: int = 0) -> int:
    """Round ``(m + s) * 2**e`` to nearest-even and return the binary32 bits.

    ``m`` is a non-negative integer and ``s`` in ``[0, 1)`` is a fraction
    that is nonzero exactly when ``sticky`` is true (it records bits that were
    truncated by the caller).  When ``sticky`` is set the caller must supply
    at least 26 significant bits in ``m`` so that the rounding position lies
    strictly inside ``m``.

    The result is rounded once, directly onto the binary32 grid: normal
    numbers keep 24 significant bits and results below ``2**-126`` are
    rounded at the fixed denormal spacing ``2**-149``.  Overflow gives
    infinity.  A zero ``m`` gives a signed zero.
    """
    sign_bit = sign << 31
    if m == 0:
        return sign_bit
    n = m.bit_length()
    # Exponent of the least significant bit of the result.
    lsb_exp = max(e + n - 24, MIN_EXP)
    shift = lsb_exp - e
    if shift > 0:
        if shift > n + 1:
            # Far below half of the smallest step: rounds to zero.
            return sign_bit
        q = m >> shift
        rem = m & ((1 << shift) - 1)
        half = 1 << (shift - 1)
        if rem > half or (rem == half and (sticky or (q & 1))):
            q += 1
    else:
        q = m << -shift
    # Adding the biased exponent to the significand (hidden bit included)
    # makes a rounding carry, and the denormal -> normal transition, work out.
    bits = ((lsb_exp - MIN_EXP) << 23) + q
    if bits >= INF:
        return sign_bit | INF
    return sign_bit | bits


__all__ = ["round_pack"]
