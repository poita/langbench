"""Affine matrices and ``transform`` attribute parsing.

A matrix is a 6-tuple ``(a, b, c, d, e, f)`` mapping ``(x, y)`` to
``(a*x + c*y + e, b*x + d*y + f)``.
"""

from __future__ import annotations

import math
import re

from .values import parse_number_list

__all__ = ["Matrix", "IDENTITY", "multiply", "translate", "scale", "apply", "parse_transform"]

Matrix = tuple[float, float, float, float, float, float]

IDENTITY: Matrix = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def multiply(m: Matrix, n: Matrix) -> Matrix:
    """Return ``m * n`` (``n`` is applied to coordinates first)."""
    a, b, c, d, e, f = m
    a2, b2, c2, d2, e2, f2 = n
    return (
        a * a2 + c * b2,
        b * a2 + d * b2,
        a * c2 + c * d2,
        b * c2 + d * d2,
        a * e2 + c * f2 + e,
        b * e2 + d * f2 + f,
    )


def translate(tx: float, ty: float = 0.0) -> Matrix:
    return (1.0, 0.0, 0.0, 1.0, tx, ty)


def scale(sx: float, sy: float | None = None) -> Matrix:
    return (sx, 0.0, 0.0, sx if sy is None else sy, 0.0, 0.0)


def apply(m: Matrix, x: float, y: float) -> tuple[float, float]:
    """Transform the point ``(x, y)`` by *m*."""
    return m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]


_FUNC = re.compile(r"([A-Za-z]+)\s*\(([^)]*)\)")


def _rotate(a: float) -> Matrix:
    r = math.radians(a)
    c, s = math.cos(r), math.sin(r)
    return (c, s, -s, c, 0.0, 0.0)


def parse_transform(text: str | None) -> Matrix:
    """Parse a ``transform`` attribute into a single matrix.

    Unknown functions and functions with too few arguments are skipped.
    """
    m = IDENTITY
    if not text:
        return m
    for fm in _FUNC.finditer(text):
        name = fm.group(1)
        args = parse_number_list(fm.group(2))
        n = len(args)
        if name == "matrix" and n >= 6:
            t: Matrix = (args[0], args[1], args[2], args[3], args[4], args[5])
        elif name == "translate" and n >= 1:
            t = translate(args[0], args[1] if n >= 2 else 0.0)
        elif name == "scale" and n >= 1:
            t = scale(args[0], args[1] if n >= 2 else None)
        elif name == "rotate" and n >= 1:
            t = _rotate(args[0])
            if n >= 3:
                t = multiply(multiply(translate(args[1], args[2]), t), translate(-args[1], -args[2]))
        elif name == "skewX" and n >= 1:
            t = (1.0, 0.0, math.tan(math.radians(args[0])), 1.0, 0.0, 0.0)
        elif name == "skewY" and n >= 1:
            t = (1.0, math.tan(math.radians(args[0])), 0.0, 1.0, 0.0, 0.0)
        else:
            continue
        m = multiply(m, t)
    return m
