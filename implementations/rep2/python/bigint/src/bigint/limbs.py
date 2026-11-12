"""Magnitude arithmetic on little-endian limb lists in base 10**9.

A *magnitude* is a ``list[int]`` of limbs, least significant first, each in
``range(BASE)``, with no most-significant zero limbs.  Zero is the empty list.
All functions treat their arguments as read-only and return fresh lists.

Every intermediate integer stays below 2**63, i.e. fits a machine word.
"""

from __future__ import annotations

BASE_DIGITS = 9
BASE = 10**BASE_DIGITS

# Number of schoolbook rows accumulated before a partial carry pass.  Each row
# adds < BASE**2 (< 1e18) to a column; 8 rows plus the leftovers of the last
# pass stay below 2**63 (~9.22e18).
_ROW_BLOCK = 8

Mag = list[int]


def _trim(a: Mag) -> Mag:
    """Drop most-significant zero limbs in place and return ``a``."""
    while a and a[-1] == 0:
        a.pop()
    return a


def from_digits(digits: str) -> Mag:
    """Convert a string of ASCII decimal digits to a magnitude (linear time)."""
    out: Mag = []
    end = len(digits)
    while end > 0:
        start = max(0, end - BASE_DIGITS)
        out.append(int(digits[start:end]))
        end = start
    return _trim(out)


def to_digits(a: Mag) -> str:
    """Convert a magnitude to canonical decimal digits (linear time)."""
    if not a:
        return "0"
    parts = [str(a[-1])]
    parts.extend(f"{limb:09d}" for limb in reversed(a[:-1]))
    return "".join(parts)


def compare(a: Mag, b: Mag) -> int:
    """Three-way comparison of two magnitudes: -1, 0 or 1."""
    if len(a) != len(b):
        return -1 if len(a) < len(b) else 1
    for x, y in zip(reversed(a), reversed(b)):
        if x != y:
            return -1 if x < y else 1
    return 0


def add(a: Mag, b: Mag) -> Mag:
    """Return ``a + b``."""
    if len(a) < len(b):
        a, b = b, a
    out: Mag = []
    carry = 0
    for i, x in enumerate(a):
        s = x + carry + (b[i] if i < len(b) else 0)
        if s >= BASE:
            s -= BASE
            carry = 1
        else:
            carry = 0
        out.append(s)
    if carry:
        out.append(1)
    return out


def sub(a: Mag, b: Mag) -> Mag:
    """Return ``a - b``; requires ``a >= b``."""
    out: Mag = []
    borrow = 0
    nb = len(b)
    for i, x in enumerate(a):
        d = x - borrow - (b[i] if i < nb else 0)
        if d < 0:
            d += BASE
            borrow = 1
        else:
            borrow = 0
        out.append(d)
    return _trim(out)


def mul_small(a: Mag, m: int) -> Mag:
    """Return ``a * m`` for a single limb ``0 <= m < BASE``."""
    if m == 0 or not a:
        return []
    out: Mag = []
    carry = 0
    for x in a:
        carry, low = divmod(x * m + carry, BASE)
        out.append(low)
    if carry:
        out.append(carry)
    return out


def divmod_small(a: Mag, m: int) -> tuple[Mag, int]:
    """Return ``(a // m, a % m)`` for a single limb ``0 < m < BASE``."""
    out = [0] * len(a)
    rem = 0
    for i in range(len(a) - 1, -1, -1):
        q, rem = divmod(rem * BASE + a[i], m)
        out[i] = q
    return _trim(out), rem


def mul(a: Mag, b: Mag) -> Mag:
    """Return ``a * b`` using schoolbook long multiplication, O(len(a)*len(b)).

    Rows are accumulated column-wise without carrying; a vectorised partial
    carry pass runs every few rows so that columns never overflow a word.
    """
    if not a or not b:
        return []
    if len(a) < len(b):
        a, b = b, a
    n, m = len(a), len(b)
    if m == 1:
        return mul_small(a, b[0])
    acc = [0] * (n + m)
    pending = 0
    for i, bi in enumerate(b):
        if bi == 0:
            continue
        acc[i : i + n] = [c + bi * x for c, x in zip(acc[i : i + n], a)]
        pending += 1
        if pending == _ROW_BLOCK:
            pending = 0
            # Columns <= i receive no further rows, so the window starts at i.
            _partial_carry(acc, i, min(i + n + 2, n + m))
    # Final sequential carry propagation.
    carry = 0
    for k in range(n + m):
        carry, acc[k] = divmod(acc[k] + carry, BASE)
    return _trim(acc)


def _partial_carry(acc: list[int], lo: int, hi: int) -> None:
    """Shift each column's overflow into the next one, over ``acc[lo:hi]``.

    Afterwards every column in the window is below ``BASE + 10**10``.  The
    overflow of the last window column is zero by the size bound on the
    partial product, so nothing is lost.
    """
    seg = acc[lo:hi]
    low = [x % BASE for x in seg]
    high = [x // BASE for x in seg]
    acc[lo] = low[0]
    acc[lo + 1 : hi] = [x + y for x, y in zip(low[1:], high)]


def divmod_mag(u: Mag, v: Mag) -> tuple[Mag, Mag]:
    """Return ``(quotient, remainder)`` of ``u / v`` (Knuth's Algorithm D).

    ``v`` must be non-zero.  Runs in O((len(u) - len(v) + 1) * len(v)).
    """
    if not v:
        raise ZeroDivisionError("division by zero")
    if compare(u, v) < 0:
        return [], list(u)
    n = len(v)
    if n == 1:
        q, r = divmod_small(u, v[0])
        return q, ([r] if r else [])

    # D1: normalise so the divisor's top limb is >= BASE // 2.
    d = BASE // (v[-1] + 1)
    vn = mul_small(v, d) if d != 1 else list(v)
    un = mul_small(u, d) if d != 1 else list(u)
    un.extend([0] * (len(u) + 1 - len(un)))  # exactly len(u) + 1 limbs
    m = len(u) - n
    q = [0] * (m + 1)
    vtop = vn[-1]
    vsec = vn[-2]

    for j in range(m, -1, -1):
        # D3: estimate the quotient digit from the top limbs.
        num = un[j + n] * BASE + un[j + n - 1]
        qhat, rhat = divmod(num, vtop)
        un2 = un[j + n - 2]
        while qhat >= BASE or qhat * vsec > rhat * BASE + un2:
            qhat -= 1
            rhat += vtop
            if rhat >= BASE:
                break
        if qhat == 0:
            continue
        # D4: multiply and subtract qhat * vn from un[j : j + n + 1].
        carry = 0
        borrow = 0
        for i in range(n):
            carry, low = divmod(qhat * vn[i] + carry, BASE)
            t = un[i + j] - low - borrow
            if t < 0:
                un[i + j] = t + BASE
                borrow = 1
            else:
                un[i + j] = t
                borrow = 0
        t = un[j + n] - carry - borrow
        if t < 0:
            # D6: qhat was one too large; add the divisor back.
            qhat -= 1
            carry = 0
            for i in range(n):
                s = un[i + j] + vn[i] + carry
                if s >= BASE:
                    s -= BASE
                    carry = 1
                else:
                    carry = 0
                un[i + j] = s
            t += carry
        un[j + n] = t
        q[j] = qhat

    # D8: denormalise the remainder.
    rem = _trim(un[:n])
    if d != 1 and rem:
        rem, _ = divmod_small(rem, d)
    return _trim(q), rem
