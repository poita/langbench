"""The five arithmetic operations on raw binary32 bit patterns.

Every function takes and returns ``int`` bit patterns in ``range(2**32)``.
All intermediates are integers that fit in 64 bits; there is no use of host
floating point.  Each operation computes a truncated result plus a sticky
bit and hands it to :func:`softfloat.rounding.round_pack`, the only place
where rounding happens.
"""

from __future__ import annotations

from .bits import (
    ABS_MASK,
    INF,
    QNAN,
    SIGN_MASK,
    is_inf,
    is_nan,
    is_zero,
    normalize,
    unpack,
)
from .rounding import round_pack

# Guard/round/sticky bits kept below the 24-bit significand in addition.
_GRS = 3


def add(a: int, b: int) -> int:
    """Return ``a + b``."""
    if is_nan(a) or is_nan(b):
        return QNAN
    if is_inf(a):
        if is_inf(b) and (a ^ b) & SIGN_MASK:
            return QNAN
        return a
    if is_inf(b):
        return b
    if is_zero(a):
        if is_zero(b):
            # Same-signed zeros keep their sign; otherwise +0.
            return a & b & SIGN_MASK
        return b
    if is_zero(b):
        return a

    # Order by magnitude so that ``a`` is the larger operand.
    if (a & ABS_MASK) < (b & ABS_MASK):
        a, b = b, a
    sign = a >> 31
    ma, ea = unpack(a)
    mb, eb = unpack(b)
    ma <<= _GRS
    mb <<= _GRS
    d = ea - eb
    if d:
        if d > 26:
            mb = 1  # everything shifted out: only the sticky bit remains
        else:
            lost = mb & ((1 << d) - 1)
            mb = (mb >> d) | (1 if lost else 0)
    if (a ^ b) & SIGN_MASK:
        m = ma - mb
        if m == 0:
            return 0
    else:
        m = ma + mb
    return round_pack(sign, m, ea - _GRS)


def sub(a: int, b: int) -> int:
    """Return ``a - b`` (identical to ``a + (-b)``)."""
    return add(a, b ^ SIGN_MASK)


def mul(a: int, b: int) -> int:
    """Return ``a * b``."""
    if is_nan(a) or is_nan(b):
        return QNAN
    sign = (a ^ b) >> 31
    if is_inf(a) or is_inf(b):
        if is_zero(a) or is_zero(b):
            return QNAN
        return (sign << 31) | INF
    if is_zero(a) or is_zero(b):
        return sign << 31
    ma, ea = unpack(a)
    mb, eb = unpack(b)
    return round_pack(sign, ma * mb, ea + eb)


def div(a: int, b: int) -> int:
    """Return ``a / b``."""
    if is_nan(a) or is_nan(b):
        return QNAN
    sign = (a ^ b) >> 31
    if is_inf(a):
        if is_inf(b):
            return QNAN
        return (sign << 31) | INF
    if is_inf(b):
        return sign << 31
    if is_zero(b):
        if is_zero(a):
            return QNAN
        return (sign << 31) | INF
    if is_zero(a):
        return sign << 31
    ma, ea = normalize(*unpack(a))
    mb, eb = normalize(*unpack(b))
    # Both significands are in [2**23, 2**24), so the quotient of the shifted
    # dividend has 26 or 27 bits: enough for 24 bits plus guard and sticky.
    q, r = divmod(ma << 26, mb)
    return round_pack(sign, q, ea - eb - 26, 1 if r else 0)


def sqrt(a: int) -> int:
    """Return the square root of ``a``."""
    if is_nan(a):
        return QNAN
    if is_zero(a):
        return a
    if a & SIGN_MASK:
        return QNAN
    if is_inf(a):
        return a
    m, e = normalize(*unpack(a))
    if e & 1:
        m <<= 1
        e -= 1
    # value = m * 2**e with e even; scale by an even power of two so the
    # root has at least 26 bits.
    num = m << 28
    e -= 28
    root, rem = _isqrt_restoring(num)
    return round_pack(0, root, e // 2, 1 if rem else 0)


def _isqrt_restoring(num: int) -> tuple[int, int]:
    """Restoring digit-by-digit integer square root (``num < 2**56``).

    Returns ``(root, remainder)`` with ``root**2 + remainder == num``.
    """
    root = 0
    bit = 1 << 54
    while bit > num:
        bit >>= 2
    while bit:
        trial = root + bit
        if num >= trial:
            num -= trial
            root = (root >> 1) + bit
        else:
            root >>= 1
        bit >>= 2
    return root, num
