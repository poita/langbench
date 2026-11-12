"""The dense matrix type."""

from __future__ import annotations

from collections.abc import Iterable, Iterator, Sequence


class Matrix:
    """A dense real matrix of IEEE-754 doubles, stored as a list of rows.

    The constructor copies its argument, so a ``Matrix`` never aliases the
    caller's data.  Matrices have at least one row and one column.  Algorithms
    in this package treat matrices as immutable values and return new ones.
    """

    __slots__ = ("rows", "cols", "_data")

    def __init__(self, data: Iterable[Iterable[float]]) -> None:
        rows = [[float(x) for x in row] for row in data]
        if not rows or not rows[0]:
            raise ValueError("a matrix needs at least one row and one column")
        width = len(rows[0])
        if any(len(row) != width for row in rows):
            raise ValueError("all rows must have the same length")
        self.rows: int = len(rows)
        self.cols: int = width
        self._data: list[list[float]] = rows

    # -- construction -------------------------------------------------------

    @classmethod
    def zeros(cls, rows: int, cols: int) -> "Matrix":
        """The ``rows x cols`` zero matrix."""
        return cls([[0.0] * cols for _ in range(rows)])

    @classmethod
    def identity(cls, n: int) -> "Matrix":
        """The ``n x n`` identity matrix."""
        return cls([[1.0 if i == j else 0.0 for j in range(n)] for i in range(n)])

    @classmethod
    def scalar(cls, value: float) -> "Matrix":
        """The 1x1 matrix holding ``value``."""
        return cls([[value]])

    @classmethod
    def from_columns(cls, columns: Sequence[Sequence[float]]) -> "Matrix":
        """Build a matrix whose ``j``-th column is ``columns[j]``."""
        return cls(zip(*columns))

    # -- inspection ---------------------------------------------------------

    @property
    def shape(self) -> tuple[int, int]:
        """``(rows, cols)``."""
        return (self.rows, self.cols)

    @property
    def is_square(self) -> bool:
        return self.rows == self.cols

    def __getitem__(self, index: tuple[int, int]) -> float:
        i, j = index
        return self._data[i][j]

    def row(self, i: int) -> list[float]:
        """A copy of row ``i``."""
        return list(self._data[i])

    def column(self, j: int) -> list[float]:
        """A copy of column ``j``."""
        return [row[j] for row in self._data]

    def to_rows(self) -> list[list[float]]:
        """A copy of the entries as a list of rows."""
        return [list(row) for row in self._data]

    def to_columns(self) -> list[list[float]]:
        """A copy of the entries as a list of columns."""
        return [list(col) for col in zip(*self._data)]

    def iter_rows(self) -> Iterator[Sequence[float]]:
        """Iterate over the rows without copying.  Callers must not mutate."""
        return iter(self._data)

    def is_symmetric(self) -> bool:
        """True if square with ``A[i][j] == A[j][i]`` as exact doubles."""
        if not self.is_square:
            return False
        return self._data == [list(col) for col in zip(*self._data)]

    # -- operations ---------------------------------------------------------

    def transpose(self) -> "Matrix":
        """The transpose, an ``n x m`` matrix."""
        return Matrix(zip(*self._data))

    @property
    def T(self) -> "Matrix":
        return self.transpose()

    # -- dunder -------------------------------------------------------------

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Matrix):
            return NotImplemented
        return self._data == other._data

    __hash__ = None  # type: ignore[assignment]

    def __repr__(self) -> str:
        return f"Matrix({self._data!r})"
