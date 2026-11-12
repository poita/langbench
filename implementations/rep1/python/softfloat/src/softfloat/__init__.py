"""Software IEEE-754 binary32 arithmetic using only integer operations.

Public API (all values are raw 32-bit patterns as ``int``)::

    >>> from softfloat import add, div, sqrt
    >>> hex(add(0x3F800000, 0x3F800000))   # 1.0 + 1.0
    '0x40000000'
    >>> hex(div(0x3F800000, 0x40400000))   # 1.0 / 3.0
    '0x3eaaaaab'
    >>> hex(sqrt(0x40000000))              # sqrt(2.0)
    '0x3fb504f3'

Rounding is round-to-nearest-even with full gradual underflow; every NaN
result is the canonical quiet NaN :data:`QNAN`.
"""

from .api import evaluate_line, evaluate_lines, format_bits, parse_bits
from .bits import INF, QNAN
from .ops import add, div, mul, sqrt, sub

__all__ = [
    "INF",
    "QNAN",
    "add",
    "div",
    "evaluate_line",
    "evaluate_lines",
    "format_bits",
    "mul",
    "parse_bits",
    "sqrt",
    "sub",
]
