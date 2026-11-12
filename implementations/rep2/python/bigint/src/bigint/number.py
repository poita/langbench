"""The signed :class:`BigInt` type."""

from __future__ import annotations

from . import limbs
from .limbs import BASE

__all__ = ["BASE", "BigInt"]

# Python ints passed to ``BigInt.from_int`` must fit a signed 64-bit word:
# this library never uses the built-in unbounded type to hold big values.
_WORD_LIMIT = 2**63


class BigInt:
    """An immutable arbitrary-precision signed integer.

    Internally a sign (``-1``, ``0`` or ``1``) and a magnitude of base-10**9
    limbs.  Zero always has sign ``0``, so there is no negative zero.

    Arithmetic operators ``+ - * **``, unary ``-``/``abs``, comparisons and
    ``str`` are supported between ``BigInt`` instances.  Division is
    *truncating* (C semantics), which differs from Python's ``//`` and ``%``,
    so it is exposed as explicit methods: :meth:`div_trunc`,
    :meth:`rem_trunc` and :meth:`divmod_trunc`.
    """

    __slots__ = ("_sign", "_mag")

    def __init__(self, sign: int = 0, mag: list[int] | None = None) -> None:
        """Low-level constructor; prefer :meth:`parse` or :meth:`from_int`."""
        mag = [] if mag is None else mag
        self._mag = mag
        self._sign = sign if mag else 0

    # -- construction ------------------------------------------------------

    @classmethod
    def parse(cls, text: str) -> BigInt:
        """Parse ``-?[0-9]+`` (leading zeros and ``-0`` allowed).

        Raises ``ValueError`` for any other text.  Runs in linear time.
        """
        negative = text.startswith("-")
        digits = text[1:] if negative else text
        if not digits or not (digits.isascii() and digits.isdigit()):
            raise ValueError(f"invalid integer literal: {text!r}")
        mag = limbs.from_digits(digits.lstrip("0"))
        return cls(-1 if negative else 1, mag)

    @classmethod
    def from_int(cls, value: int) -> BigInt:
        """Build from a Python int that fits a signed 64-bit machine word."""
        if not -_WORD_LIMIT <= value < _WORD_LIMIT:
            raise ValueError("from_int only accepts machine-word values")
        sign = (value > 0) - (value < 0)
        value = -value if value < 0 else value
        mag: list[int] = []
        while value:
            value, limb = divmod(value, BASE)
            mag.append(limb)
        return cls(sign, mag)

    # -- inspection --------------------------------------------------------

    @property
    def sign(self) -> int:
        """-1, 0 or 1."""
        return self._sign

    def __str__(self) -> str:
        text = limbs.to_digits(self._mag)
        return "-" + text if self._sign < 0 else text

    def __repr__(self) -> str:
        return f"BigInt({str(self)!r})"

    def __bool__(self) -> bool:
        return self._sign != 0

    def __hash__(self) -> int:
        return hash((self._sign, tuple(self._mag)))

    # -- comparison --------------------------------------------------------

    def compare(self, other: BigInt) -> int:
        """Three-way numeric comparison: -1, 0 or 1."""
        if self._sign != other._sign:
            return -1 if self._sign < other._sign else 1
        c = limbs.compare(self._mag, other._mag)
        return c if self._sign >= 0 else -c

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, BigInt):
            return NotImplemented
        return self._sign == other._sign and self._mag == other._mag

    def __lt__(self, other: BigInt) -> bool:
        return self.compare(other) < 0

    def __le__(self, other: BigInt) -> bool:
        return self.compare(other) <= 0

    def __gt__(self, other: BigInt) -> bool:
        return self.compare(other) > 0

    def __ge__(self, other: BigInt) -> bool:
        return self.compare(other) >= 0

    # -- arithmetic --------------------------------------------------------

    def __neg__(self) -> BigInt:
        return BigInt(-self._sign, self._mag)

    def __abs__(self) -> BigInt:
        return BigInt(abs(self._sign), self._mag)

    def __add__(self, other: BigInt) -> BigInt:
        if not isinstance(other, BigInt):
            return NotImplemented
        if self._sign == 0:
            return other
        if other._sign == 0:
            return self
        if self._sign == other._sign:
            return BigInt(self._sign, limbs.add(self._mag, other._mag))
        c = limbs.compare(self._mag, other._mag)
        if c == 0:
            return BigInt()
        if c > 0:
            return BigInt(self._sign, limbs.sub(self._mag, other._mag))
        return BigInt(other._sign, limbs.sub(other._mag, self._mag))

    def __sub__(self, other: BigInt) -> BigInt:
        if not isinstance(other, BigInt):
            return NotImplemented
        return self + (-other)

    def __mul__(self, other: BigInt) -> BigInt:
        if not isinstance(other, BigInt):
            return NotImplemented
        return BigInt(self._sign * other._sign, limbs.mul(self._mag, other._mag))

    def divmod_trunc(self, other: BigInt) -> tuple[BigInt, BigInt]:
        """Return ``(q, r)`` with ``q`` truncated toward zero and
        ``self == q * other + r``, ``r`` zero or signed like ``self``.

        Raises ``ZeroDivisionError`` if ``other`` is zero.
        """
        if other._sign == 0:
            raise ZeroDivisionError("division by zero")
        q, r = limbs.divmod_mag(self._mag, other._mag)
        return BigInt(self._sign * other._sign, q), BigInt(self._sign, r)

    def div_trunc(self, other: BigInt) -> BigInt:
        """Quotient truncated toward zero."""
        return self.divmod_trunc(other)[0]

    def rem_trunc(self, other: BigInt) -> BigInt:
        """Remainder with the sign of ``self``."""
        return self.divmod_trunc(other)[1]

    def pow(self, exponent: BigInt) -> BigInt:
        """Return ``self ** exponent`` by binary exponentiation.

        ``x ** 0 == 1`` for every ``x`` (including 0).  Raises ``ValueError``
        for a negative exponent and ``OverflowError`` if the exponent does not
        fit a machine word and the base is not 0, 1 or -1 (the result would be
        astronomically large).
        """
        if exponent._sign < 0:
            raise ValueError("negative exponent")
        if exponent._sign == 0:
            return BigInt.from_int(1)
        # Base 0, 1 and -1 have trivial powers whatever the exponent's size.
        if self._sign == 0:
            return self
        if self._mag == [1]:
            if self._sign > 0 or exponent._mag[0] % 2 == 0:
                return BigInt.from_int(1)
            return self
        if len(exponent._mag) > 2:
            raise OverflowError("exponent too large")
        e = 0
        for limb in reversed(exponent._mag):
            e = e * BASE + limb  # < 1e18, fits a machine word
        negative = self._sign < 0 and e % 2 == 1
        base = self._mag
        result = base
        for bit in bin(e)[3:]:  # left-to-right; leading 1 is the initial value
            result = limbs.mul(result, result)
            if bit == "1":
                result = limbs.mul(result, base)
        return BigInt(-1 if negative else 1, result)

    def __pow__(self, exponent: BigInt) -> BigInt:
        if not isinstance(exponent, BigInt):
            return NotImplemented
        return self.pow(exponent)
