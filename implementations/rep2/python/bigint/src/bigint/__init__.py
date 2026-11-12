"""Arbitrary-precision signed integers implemented from scratch.

Values are a sign plus a magnitude stored as little-endian limbs in base
10**9, using the classical algorithms: linear parsing/printing/add/sub,
schoolbook multiplication, Knuth Algorithm D division and binary
exponentiation.  No unbounded Python ``int`` is ever used to hold a number
bigger than a machine word.

Public API::

    from bigint import BigInt

    a = BigInt.parse("-123456789012345678901234567890")
    b = BigInt.from_int(97)
    str(a * b), a.divmod_trunc(b), a.pow(b), a.compare(b)

The remaining modules are internal: :mod:`bigint.limbs` (magnitude
algorithms), :mod:`bigint.number` (the signed :class:`BigInt` type) and
:mod:`bigint.cli` (the query-processing command-line tool).
"""

from .number import BASE, BigInt

__all__ = ["BASE", "BigInt"]
__version__ = "1.0.0"
