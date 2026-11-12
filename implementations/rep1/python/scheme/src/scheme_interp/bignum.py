"""Arbitrary-precision integer arithmetic, implemented from scratch.

Scheme integers are represented as

* a Python ``int`` whenever the value fits comfortably in a machine word
  (``|n| < 2**62``), and
* a :class:`BigInt` otherwise.

The representation is *canonical*: a value that fits in a machine word is
never wrapped in a :class:`BigInt`.  Python's own unbounded integers are
used only for such machine-word values (and for single limbs and the
intermediate products of two limbs, which stay below ``2**62``).

A :class:`BigInt` is a sign and a magnitude, the magnitude being a list of
limbs in base ``2**30``, least significant first, without leading zeros.
The algorithms are the classical ones: schoolbook addition, subtraction and
multiplication, Knuth's Algorithm D for division, and repeated division by
``10**9`` for decimal output.

The functions :func:`add`, :func:`sub`, :func:`mul`, :func:`neg`,
:func:`quotient`, :func:`remainder`, :func:`compare`, :func:`to_string` and
:func:`parse` accept and return Scheme integers (``int`` or ``BigInt``).
"""

from __future__ import annotations

from typing import Union

LIMB_BITS = 30
BASE = 1 << LIMB_BITS
MASK = BASE - 1

#: Integers with ``|n| < SMALL_LIMIT`` are kept as Python ``int``.
SMALL_LIMIT = 1 << 62
#: Largest ``|n|`` for which a product of two ``int`` operands is still
#: guaranteed to be a machine-word value.
MUL_LIMIT = 1 << 31

DEC_CHUNK = 10**9
DEC_CHUNK_DIGITS = 9

Mag = list  # list[int], little-endian base-2**30 limbs, no leading zeros


class BigInt:
    """A signed integer too large for a machine word (see module docs)."""

    __slots__ = ("neg", "mag")

    def __init__(self, neg: bool, mag: Mag) -> None:
        self.neg = neg
        self.mag = mag

    def __repr__(self) -> str:
        return f"BigInt({to_string(self)})"


Integer = Union[int, BigInt]


# ---------------------------------------------------------------------------
# Magnitude (unsigned) arithmetic
# ---------------------------------------------------------------------------


def _mag_from_word(n: int) -> Mag:
    """Limbs of a non-negative machine-word value."""
    out = []
    while n:
        out.append(n & MASK)
        n >>= LIMB_BITS
    return out


def _strip(mag: Mag) -> Mag:
    while mag and mag[-1] == 0:
        mag.pop()
    return mag


def _mag_cmp(a: Mag, b: Mag) -> int:
    if len(a) != len(b):
        return -1 if len(a) < len(b) else 1
    for i in range(len(a) - 1, -1, -1):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    return 0


def _mag_add(a: Mag, b: Mag) -> Mag:
    if len(a) < len(b):
        a, b = b, a
    out = []
    carry = 0
    nb = len(b)
    for i in range(len(a)):
        s = a[i] + carry + (b[i] if i < nb else 0)
        out.append(s & MASK)
        carry = s >> LIMB_BITS
    if carry:
        out.append(carry)
    return out


def _mag_sub(a: Mag, b: Mag) -> Mag:
    """``a - b`` for ``a >= b``."""
    out = []
    borrow = 0
    nb = len(b)
    for i in range(len(a)):
        d = a[i] - borrow - (b[i] if i < nb else 0)
        if d < 0:
            d += BASE
            borrow = 1
        else:
            borrow = 0
        out.append(d)
    return _strip(out)


def _mag_mul_small(a: Mag, m: int) -> Mag:
    """``a * m`` for a single limb ``0 < m < BASE``."""
    out = []
    carry = 0
    for x in a:
        p = x * m + carry
        out.append(p & MASK)
        carry = p >> LIMB_BITS
    if carry:
        out.append(carry)
    return out


def _mag_mul(a: Mag, b: Mag) -> Mag:
    """Schoolbook multiplication."""
    if len(a) < len(b):
        a, b = b, a
    if len(b) == 1:
        return _mag_mul_small(a, b[0])
    out = [0] * (len(a) + len(b))
    for j, y in enumerate(b):
        if y == 0:
            continue
        carry = 0
        k = j
        for x in a:
            t = out[k] + x * y + carry
            out[k] = t & MASK
            carry = t >> LIMB_BITS
            k += 1
        out[k] += carry
    return _strip(out)


def _mag_divmod_small(a: Mag, d: int) -> tuple[Mag, int]:
    """Divide by a single limb ``0 < d < BASE``; returns (quotient, remainder)."""
    q = [0] * len(a)
    rem = 0
    for i in range(len(a) - 1, -1, -1):
        cur = (rem << LIMB_BITS) | a[i]
        q[i], rem = divmod(cur, d)
    return _strip(q), rem


def _mag_shl(a: Mag, s: int, extra: bool) -> Mag:
    """Shift left by ``0 <= s < LIMB_BITS`` bits, optionally appending a limb."""
    out = []
    carry = 0
    for x in a:
        t = (x << s) | carry
        out.append(t & MASK)
        carry = t >> LIMB_BITS
    if extra:
        out.append(carry)
    return out


def _mag_divmod(u: Mag, v: Mag) -> tuple[Mag, Mag]:
    """Knuth's Algorithm D.  ``v`` must be non-empty (no leading zeros)."""
    if _mag_cmp(u, v) < 0:
        return [], list(u)
    n = len(v)
    if n == 1:
        q, r = _mag_divmod_small(u, v[0])
        return q, ([r] if r else [])
    m = len(u) - n
    # D1: normalise so that the top limb of the divisor has its high bit set.
    s = LIMB_BITS - v[-1].bit_length()
    vn = _mag_shl(v, s, False)
    un = _mag_shl(u, s, True)
    q = [0] * (m + 1)
    v1 = vn[n - 1]
    v2 = vn[n - 2]
    for j in range(m, -1, -1):
        # D3: estimate the quotient digit.
        num = (un[j + n] << LIMB_BITS) | un[j + n - 1]
        qhat, rhat = divmod(num, v1)
        while qhat >= BASE or qhat * v2 > ((rhat << LIMB_BITS) | un[j + n - 2]):
            qhat -= 1
            rhat += v1
            if rhat >= BASE:
                break
        # D4: multiply and subtract.
        borrow = 0
        carry = 0
        for i in range(n):
            p = qhat * vn[i] + carry
            carry = p >> LIMB_BITS
            t = un[i + j] - (p & MASK) - borrow
            if t < 0:
                t += BASE
                borrow = 1
            else:
                borrow = 0
            un[i + j] = t
        t = un[j + n] - carry - borrow
        if t < 0:
            # D6: the estimate was one too large; add the divisor back.
            qhat -= 1
            un[j + n] = (t + BASE) & MASK
            c = 0
            for i in range(n):
                t2 = un[i + j] + vn[i] + c
                un[i + j] = t2 & MASK
                c = t2 >> LIMB_BITS
            un[j + n] = (un[j + n] + c) & MASK
        else:
            un[j + n] = t
        q[j] = qhat
    # D8: denormalise the remainder.
    r = []
    for i in range(n):
        lo = un[i] >> s
        hi = (un[i + 1] << (LIMB_BITS - s)) & MASK if i + 1 < len(un) else 0
        r.append(lo | hi)
    return _strip(q), _strip(r)


# ---------------------------------------------------------------------------
# Signed values and normalisation
# ---------------------------------------------------------------------------


def _parts(x: Integer) -> tuple[bool, Mag]:
    """(negative?, magnitude) of a Scheme integer."""
    if type(x) is int:
        if x < 0:
            return True, _mag_from_word(-x)
        return False, _mag_from_word(x)
    return x.neg, x.mag


def _make(neg: bool, mag: Mag) -> Integer:
    """Build the canonical Scheme integer for a sign and magnitude."""
    _strip(mag)
    n = len(mag)
    if n == 0:
        return 0
    if n <= 2 or (n == 3 and mag[2] < 4):
        v = mag[0] | (mag[1] << LIMB_BITS) if n > 1 else mag[0]
        if n == 3:
            v |= mag[2] << (2 * LIMB_BITS)
        return -v if neg else v
    return BigInt(neg, mag)


def from_word(n: int) -> Integer:
    """Canonicalise a machine-word ``int`` (``|n| < 2**63``)."""
    if -SMALL_LIMIT < n < SMALL_LIMIT:
        return n
    return _make(n < 0, _mag_from_word(-n if n < 0 else n))


def is_integer(x: object) -> bool:
    """True if ``x`` is a Scheme integer (``bool`` is not)."""
    t = type(x)
    return t is int or t is BigInt


# ---------------------------------------------------------------------------
# Public operations
# ---------------------------------------------------------------------------


def neg(a: Integer) -> Integer:
    if type(a) is int:
        return -a  # |a| < 2**62, so the result is again a small int
    return _make(not a.neg, list(a.mag))


def add(a: Integer, b: Integer) -> Integer:
    if type(a) is int and type(b) is int:
        return from_word(a + b)
    an, am = _parts(a)
    bn, bm = _parts(b)
    if an == bn:
        return _make(an, _mag_add(am, bm))
    c = _mag_cmp(am, bm)
    if c == 0:
        return 0
    if c > 0:
        return _make(an, _mag_sub(am, bm))
    return _make(bn, _mag_sub(bm, am))


def sub(a: Integer, b: Integer) -> Integer:
    if type(a) is int and type(b) is int:
        return from_word(a - b)
    return add(a, neg(b))


def mul(a: Integer, b: Integer) -> Integer:
    if (
        type(a) is int
        and type(b) is int
        and -MUL_LIMIT < a < MUL_LIMIT
        and -MUL_LIMIT < b < MUL_LIMIT
    ):
        return a * b
    an, am = _parts(a)
    bn, bm = _parts(b)
    if not am or not bm:
        return 0
    return _make(an != bn, _mag_mul(am, bm))


def divmod_trunc(a: Integer, b: Integer) -> tuple[Integer, Integer]:
    """Quotient truncated toward zero and the matching remainder.

    The remainder has the sign of ``a``.  ``b`` must be non-zero.
    """
    if type(a) is int and type(b) is int:
        q = abs(a) // abs(b)
        if (a < 0) != (b < 0):
            q = -q
        return q, a - b * q  # |b * q| <= |a|: stays within a machine word
    an, am = _parts(a)
    bn, bm = _parts(b)
    q, r = _mag_divmod(am, bm)
    return _make(an != bn, q), _make(an, r)


def quotient(a: Integer, b: Integer) -> Integer:
    return divmod_trunc(a, b)[0]


def remainder(a: Integer, b: Integer) -> Integer:
    return divmod_trunc(a, b)[1]


def compare(a: Integer, b: Integer) -> int:
    """Return -1, 0 or 1 as ``a`` is less than, equal to or greater than ``b``."""
    ta = type(a)
    tb = type(b)
    if ta is int:
        if tb is int:
            return -1 if a < b else (1 if a > b else 0)
        return 1 if b.neg else -1  # |b| >= 2**62 > |a|
    if tb is int:
        return -1 if a.neg else 1
    if a.neg != b.neg:
        return -1 if a.neg else 1
    c = _mag_cmp(a.mag, b.mag)
    return -c if a.neg else c


def to_string(a: Integer) -> str:
    """Decimal representation (repeated division by ``10**9``)."""
    if type(a) is int:
        return str(a)
    mag = list(a.mag)
    chunks = []
    while mag:
        mag, r = _mag_divmod_small(mag, DEC_CHUNK)
        chunks.append(r)
    parts = [str(chunks[-1])]
    for c in reversed(chunks[:-1]):
        parts.append(str(c).rjust(DEC_CHUNK_DIGITS, "0"))
    return ("-" if a.neg else "") + "".join(parts)


def parse(text: str) -> Integer:
    """Parse an optionally signed string of ASCII decimal digits."""
    negative = False
    if text[0] in "+-":
        negative = text[0] == "-"
        text = text[1:]
    mag: Mag = []
    first = len(text) % DEC_CHUNK_DIGITS
    pos = 0
    chunks = []
    if first:
        chunks.append(text[:first])
        pos = first
    while pos < len(text):
        chunks.append(text[pos : pos + DEC_CHUNK_DIGITS])
        pos += DEC_CHUNK_DIGITS
    for chunk in chunks:
        # mag = mag * 10**len(chunk) + int(chunk), a chunk being < 10**9
        scale = 10 ** len(chunk)
        digit = int(chunk)
        carry = digit
        for i in range(len(mag)):
            p = mag[i] * scale + carry
            mag[i] = p & MASK
            carry = p >> LIMB_BITS
        while carry:
            mag.append(carry & MASK)
            carry >>= LIMB_BITS
    return _make(negative, mag)
