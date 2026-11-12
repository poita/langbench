"""The signed :class:`BigInt` type built on :mod:`bigint.magnitude`."""

from __future__ import annotations

import re

from . import magnitude as mag

_DECIMAL = re.compile(r"-?[0-9]+")


class BigInt:
    """An immutable signed integer of arbitrary size.

    Values are created from decimal strings with :meth:`parse` (leading zeros
    and ``-0`` are accepted) or from machine-word integers with
    :meth:`from_int`, and printed with :func:`str`.

    Supported operators: ``+ - *`` (also unary ``-`` and :func:`abs`), ``**``
    with a non-negative exponent, and the rich comparisons. Division is
    *truncating* (C semantics), so it is exposed as :meth:`divmod_trunc`,
    :meth:`quotient` and :meth:`remainder` rather than ``//`` and ``%``, whose
    Python meaning is different.
    """

    __slots__ = ("_sign", "_mag")

    def __init__(self, sign: int, magnitude: list[int]):
        """Low-level constructor: ``sign`` in {-1, 0, 1}, ``magnitude`` normalised.

        Prefer :meth:`parse` or :meth:`from_int`.
        """
        self._sign = sign if magnitude else 0
        self._mag = magnitude

    # -- construction and printing -------------------------------------------

    @classmethod
    def parse(cls, text: str) -> BigInt:
        """Parse ``-?[0-9]+``; raises :class:`ValueError` for anything else."""
        if not _DECIMAL.fullmatch(text):
            raise ValueError(f"not a decimal integer: {text[:40]!r}")
        negative = text[0] == "-"
        m = mag.from_decimal(text[1:] if negative else text)
        return cls(-1 if negative else 1, m)

    @classmethod
    def from_int(cls, n: int) -> BigInt:
        """Convert a machine-word Python int (``|n| < 2**63``)."""
        return cls(-1 if n < 0 else 1, mag.from_small(abs(n)))

    def __str__(self) -> str:
        text = mag.to_decimal(self._mag)
        return "-" + text if self._sign < 0 else text

    def __repr__(self) -> str:
        return f"BigInt({str(self)!r})"

    # -- inspection ------------------------------------------------------------

    @property
    def sign(self) -> int:
        """-1, 0 or 1."""
        return self._sign

    def __bool__(self) -> bool:
        return self._sign != 0

    def __hash__(self) -> int:
        return hash((self._sign, tuple(self._mag)))

    # -- comparison ----------------------------------------------------------

    def compare(self, other: BigInt) -> int:
        """Three-way comparison: -1, 0 or 1."""
        if self._sign != other._sign:
            return -1 if self._sign < other._sign else 1
        c = mag.compare(self._mag, other._mag)
        return c if self._sign >= 0 else -c

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, BigInt):
            return NotImplemented
        return self._sign == other._sign and self._mag == other._mag

    def __lt__(self, other: BigInt) -> bool:
        return self._cmp_op(other) < 0

    def __le__(self, other: BigInt) -> bool:
        return self._cmp_op(other) <= 0

    def __gt__(self, other: BigInt) -> bool:
        return self._cmp_op(other) > 0

    def __ge__(self, other: BigInt) -> bool:
        return self._cmp_op(other) >= 0

    def _cmp_op(self, other: BigInt) -> int:
        if not isinstance(other, BigInt):
            raise TypeError(f"cannot compare BigInt with {type(other).__name__}")
        return self.compare(other)

    # -- arithmetic ----------------------------------------------------------

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
            return BigInt(self._sign, mag.add(self._mag, other._mag))
        c = mag.compare(self._mag, other._mag)
        if c == 0:
            return BigInt(0, [])
        if c > 0:
            return BigInt(self._sign, mag.sub(self._mag, other._mag))
        return BigInt(other._sign, mag.sub(other._mag, self._mag))

    def __sub__(self, other: BigInt) -> BigInt:
        if not isinstance(other, BigInt):
            return NotImplemented
        return self + (-other)

    def __mul__(self, other: BigInt) -> BigInt:
        if not isinstance(other, BigInt):
            return NotImplemented
        return BigInt(self._sign * other._sign, mag.mul(self._mag, other._mag))

    def divmod_trunc(self, other: BigInt) -> tuple[BigInt, BigInt]:
        """Return ``(quotient, remainder)`` with C semantics.

        The quotient is truncated toward zero and the remainder has the sign of
        ``self`` (or is zero), so ``self == q * other + r``.

        Raises :class:`ZeroDivisionError` if ``other`` is zero.
        """
        q, r = mag.divmod_(self._mag, other._mag)
        return BigInt(self._sign * other._sign, q), BigInt(self._sign, r)

    def quotient(self, other: BigInt) -> BigInt:
        """``self / other`` truncated toward zero."""
        return self.divmod_trunc(other)[0]

    def remainder(self, other: BigInt) -> BigInt:
        """``self % other`` with the sign of ``self`` (C semantics)."""
        return self.divmod_trunc(other)[1]

    def __pow__(self, exponent: BigInt | int) -> BigInt:
        """Raise to a non-negative power by repeated squaring.

        ``x ** 0 == 1`` for every ``x`` including zero. Raises
        :class:`ValueError` for a negative exponent. Exponents of 10**18 or
        more are only supported for the bases -1, 0 and 1 (anything else would
        have an astronomically large result); otherwise :class:`OverflowError`.
        """
        if isinstance(exponent, int):
            exponent = BigInt.from_int(exponent)
        if not isinstance(exponent, BigInt):
            return NotImplemented
        if exponent._sign < 0:
            raise ValueError("negative exponent")
        if exponent._sign == 0:
            return BigInt(1, [1])
        if self._sign == 0:
            return self
        if self._mag == [1]:  # +-1: only the parity of the exponent matters
            odd = exponent._mag[0] & 1  # the base 10**9 is even
            return self if odd else BigInt(1, [1])
        if len(exponent._mag) > 2:
            raise OverflowError("exponent too large")
        e = mag.to_small(exponent._mag)
        sign = -1 if self._sign < 0 and e & 1 else 1
        return BigInt(sign, mag.pow_(self._mag, e))
