"""Bit-level helpers for IEEE-754 binary32 patterns.

A binary32 value is represented throughout the library as a plain Python
``int`` in ``range(2**32)`` holding its raw bit pattern.
"""

from __future__ import annotations

SIGN_MASK = 0x8000_0000
EXP_MASK = 0x7F80_0000
FRAC_MASK = 0x007F_FFFF
HIDDEN_BIT = 0x0080_0000
ABS_MASK = 0x7FFF_FFFF

#: The one NaN the library ever produces (positive, quiet, zero payload).
QNAN = 0x7FC0_0000
#: Positive infinity.
INF = 0x7F80_0000

#: Exponent of the least significant bit of a denormal: ``2**-149``.
MIN_EXP = -149


def sign_of(bits: int) -> int:
    """Return the sign bit (0 or 1)."""
    return bits >> 31


def is_nan(bits: int) -> bool:
    """True for any NaN pattern (quiet or signaling, either sign)."""
    return (bits & ABS_MASK) > EXP_MASK


def is_inf(bits: int) -> bool:
    """True for +infinity and -infinity."""
    return (bits & ABS_MASK) == EXP_MASK


def is_zero(bits: int) -> bool:
    """True for +0 and -0."""
    return (bits & ABS_MASK) == 0


def unpack(bits: int) -> tuple[int, int]:
    """Unpack a finite nonzero pattern into ``(m, e)`` with value ``m * 2**e``.

    ``m`` is the integer significand (up to 24 bits, hidden bit included for
    normal numbers) and the sign is ignored.  Denormals are *not* normalised.
    """
    exp = (bits & EXP_MASK) >> 23
    frac = bits & FRAC_MASK
    if exp == 0:
        return frac, MIN_EXP
    return frac | HIDDEN_BIT, exp - 150


def normalize(m: int, e: int) -> tuple[int, int]:
    """Shift ``m`` left until it has exactly 24 bits, adjusting ``e``."""
    shift = 24 - m.bit_length()
    return m << shift, e - shift
