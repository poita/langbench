"""Unsigned arbitrary-precision arithmetic on little-endian digit arrays.

A *magnitude* is a ``list[int]`` of limbs in base ``10**9``, least significant
limb first, with no leading (high-end) zero limbs; zero is the empty list.
Base ``10**9`` makes decimal parsing and printing linear.

Every intermediate integer in this module fits in a signed 64-bit machine
word (|x| < 2**63): a limb product is below ``10**18`` and the deferred-carry
multiplication accumulates at most 8 of them before normalising.

All functions treat their arguments as immutable and return new lists.
"""

from __future__ import annotations

BASE_DIGITS = 9
BASE = 10**BASE_DIGITS

Magnitude = list[int]

# Number of limb products that may be accumulated in one column before the
# carries must be propagated: 8 * (BASE-1)**2 + BASE < 2**63.
_ROWS_PER_CARRY = 8


def _propagate(t: list[int], lo: int = 0, hi: int | None = None) -> int:
    """Normalise ``t[lo:hi]`` into ``[0, BASE)`` limbs, in place.

    Limbs may be negative or exceed ``BASE`` on entry. Returns the carry (which
    may be negative) leaving the top of the range.
    """
    if hi is None:
        hi = len(t)
    carry = 0
    for i in range(lo, hi):
        v = t[i] + carry
        carry = v // BASE
        t[i] = v - carry * BASE
    return carry


def _strip(m: list[int]) -> list[int]:
    """Remove high-end zero limbs in place and return the list."""
    while m and m[-1] == 0:
        m.pop()
    return m


def from_decimal(digits: str) -> Magnitude:
    """Convert a string of ASCII digits (any leading zeros) to a magnitude."""
    digits = digits.lstrip("0")
    return [int(digits[max(0, i - BASE_DIGITS) : i]) for i in range(len(digits), 0, -BASE_DIGITS)]


def to_decimal(m: Magnitude) -> str:
    """Convert a magnitude to its canonical decimal string (``"0"`` for zero)."""
    if not m:
        return "0"
    parts = [str(m[-1])]
    parts.extend(["%09d" % limb for limb in reversed(m[:-1])])
    return "".join(parts)


def from_small(n: int) -> Magnitude:
    """Convert a non-negative machine-word integer (``0 <= n < 2**63``)."""
    if not 0 <= n < 1 << 63:
        raise OverflowError("from_small needs 0 <= n < 2**63")
    out = []
    while n:
        n, r = divmod(n, BASE)
        out.append(r)
    return out


def to_small(m: Magnitude) -> int:
    """Convert a magnitude below ``BASE**2`` to a machine integer."""
    if len(m) > 2:
        raise OverflowError("magnitude too large for a machine integer")
    return sum(limb * BASE**i for i, limb in enumerate(m))


def compare(a: Magnitude, b: Magnitude) -> int:
    """Return -1, 0 or 1 as ``a`` is less than, equal to or greater than ``b``."""
    if len(a) != len(b):
        return -1 if len(a) < len(b) else 1
    for x, y in zip(reversed(a), reversed(b)):
        if x != y:
            return -1 if x < y else 1
    return 0


def add(a: Magnitude, b: Magnitude) -> Magnitude:
    """Return ``a + b``. O(len(a) + len(b))."""
    if len(a) < len(b):
        a, b = b, a
    t = [x + y for x, y in zip(a, b)]
    t.extend(a[len(b) :])
    carry = _propagate(t)
    if carry:
        t.append(carry)
    return t


def sub(a: Magnitude, b: Magnitude) -> Magnitude:
    """Return ``a - b`` for ``a >= b``. O(len(a))."""
    t = [x - y for x, y in zip(a, b)]
    t.extend(a[len(b) :])
    if _propagate(t):
        raise ValueError("sub requires a >= b")
    return _strip(t)


def mul_small(a: Magnitude, d: int) -> Magnitude:
    """Return ``a * d`` for a single limb ``0 <= d < BASE``."""
    if d == 0 or not a:
        return []
    t = [x * d for x in a]
    carry = _propagate(t)
    if carry:
        t.append(carry)
    return t


def divmod_small(a: Magnitude, d: int) -> tuple[Magnitude, int]:
    """Return ``(a // d, a % d)`` for a single limb ``0 < d < BASE``."""
    q = [0] * len(a)
    rem = 0
    for i in range(len(a) - 1, -1, -1):
        q[i], rem = divmod(rem * BASE + a[i], d)
    return _strip(q), rem


def mul(a: Magnitude, b: Magnitude) -> Magnitude:
    """Return ``a * b`` by schoolbook long multiplication. O(len(a) * len(b)).

    Rows are accumulated without carrying, up to eight at a time, and the
    carries are then propagated over the affected window only.
    """
    if not a or not b:
        return []
    if len(a) > len(b):
        a, b = b, a  # outer loop over the shorter operand
    la, lb = len(a), len(b)
    if la == 1:
        return mul_small(b, a[0])
    total = la + lb
    acc = [0] * total
    for start in range(0, la, _ROWS_PER_CARRY):
        for i in range(start, min(start + _ROWS_PER_CARRY, la)):
            ai = a[i]
            if ai:
                end = i + lb
                acc[i:end] = [x + ai * y for x, y in zip(acc[i:end], b)]
        _propagate(acc, start, min(start + lb + _ROWS_PER_CARRY + 1, total))
    return _strip(acc)


def divmod_(a: Magnitude, b: Magnitude) -> tuple[Magnitude, Magnitude]:
    """Return ``(a // b, a % b)`` using Knuth's Algorithm D.

    Raises :class:`ZeroDivisionError` if ``b`` is zero.
    O((len(a) - len(b) + 1) * len(b)).
    """
    if not b:
        raise ZeroDivisionError("division by zero")
    if compare(a, b) < 0:
        return [], list(a)
    if len(b) == 1:
        q, r = divmod_small(a, b[0])
        return q, [r] if r else []

    # D1: normalise so the divisor's top limb is >= BASE // 2.
    d = BASE // (b[-1] + 1)
    v = mul_small(b, d)
    u = mul_small(a, d)
    if len(u) == len(a):
        u.append(0)
    n = len(v)
    v1, v2 = v[-1], v[-2]
    q = [0] * (len(u) - n)

    for j in range(len(u) - n - 1, -1, -1):
        # D3: estimate the quotient limb from the top two limbs.
        num = u[j + n] * BASE + u[j + n - 1]
        qhat, rhat = divmod(num, v1)
        u2 = u[j + n - 2]
        while qhat >= BASE or qhat * v2 > rhat * BASE + u2:
            qhat -= 1
            rhat += v1
            if rhat >= BASE:
                break
        # D4: multiply and subtract.
        if qhat:
            t = [x - qhat * y for x, y in zip(u[j : j + n], v)]
            t.append(u[j + n])
            if _propagate(t):
                # D6: qhat was one too large; add the divisor back.
                qhat -= 1
                t[:n] = [x + y for x, y in zip(t, v)]
                _propagate(t)  # carry out of the top limb is discarded
            u[j : j + n + 1] = t
        q[j] = qhat

    # D8: un-normalise the remainder.
    r, rem = divmod_small(_strip(u[:n]), d)
    assert rem == 0
    return _strip(q), r


def pow_(a: Magnitude, e: int) -> Magnitude:
    """Return ``a ** e`` by binary exponentiation for a machine integer ``e >= 0``."""
    if e < 0:
        raise ValueError("negative exponent")
    result = [1]
    for bit in bin(e)[2:]:
        result = mul(result, result)
        if bit == "1":
            result = mul(result, a)
    return result
