"""Exception types for operations that cannot be carried out.

Every exception carries a short machine-readable ``code`` (also its message);
the command-line driver writes that code into the ``NNN_error.txt`` file.
"""

from __future__ import annotations


class LinalgError(Exception):
    """Base class of all errors raised on purpose by this library."""

    code: str = "error"

    def __init__(self, detail: str | None = None) -> None:
        super().__init__(self.code if detail is None else f"{self.code}: {detail}")
        self.detail = detail


class DimensionMismatch(LinalgError):
    """The shapes of the operands are incompatible with the operation."""

    code = "dimension_mismatch"


class NotSquare(LinalgError):
    """A square matrix was required."""

    code = "not_square"


class NotSymmetric(LinalgError):
    """A symmetric matrix was required (compared as exact doubles)."""

    code = "not_symmetric"


class NotPositiveDefinite(LinalgError):
    """Cholesky factorisation met a non-positive pivot."""

    code = "not_positive_definite"


class Singular(LinalgError):
    """A pivot, diagonal entry or singular value was exactly zero."""

    code = "singular"
