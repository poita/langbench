"""Matrix Market reading and writing.

Reading supports the ``coordinate`` and ``array`` formats with the ``real``,
``integer`` and ``pattern`` fields and the ``general``, ``symmetric`` and
``skew-symmetric`` symmetries.  Everything is expanded into a dense
:class:`~linalg.matrix.Matrix`.  Writing always produces ``array real
general`` with values formatted like C's ``printf("%.10e")``.
"""

from __future__ import annotations

import os
from collections.abc import Iterable
from typing import Union

from .matrix import Matrix

PathLike = Union[str, "os.PathLike[str]"]

_FORMATS = {"coordinate", "array"}
_FIELDS = {"real", "integer", "pattern"}
_SYMMETRIES = {"general", "symmetric", "skew-symmetric"}


class MatrixMarketError(ValueError):
    """The text is not a Matrix Market matrix this reader understands."""


def parse_matrix(text: str) -> Matrix:
    """Parse the text of a Matrix Market file into a dense matrix."""
    lines = text.split("\n")
    pos = 0
    while pos < len(lines) and not lines[pos].strip():
        pos += 1
    if pos == len(lines):
        raise MatrixMarketError("empty file")
    banner = lines[pos].split()
    pos += 1
    if len(banner) != 5 or banner[0].lower() != "%%matrixmarket" or banner[1].lower() != "matrix":
        raise MatrixMarketError("bad banner line")
    fmt, field, symmetry = (word.lower() for word in banner[2:])
    if fmt not in _FORMATS or field not in _FIELDS or symmetry not in _SYMMETRIES:
        raise MatrixMarketError(f"unsupported banner: {' '.join(banner)}")
    if field == "pattern" and fmt != "coordinate":
        raise MatrixMarketError("pattern requires coordinate format")

    # Comment lines (header only) and blank lines precede the size line.
    while pos < len(lines):
        stripped = lines[pos].strip()
        if stripped and not stripped.startswith("%"):
            break
        pos += 1
    if pos == len(lines):
        raise MatrixMarketError("missing size line")
    size = lines[pos].split()
    pos += 1
    # Data is one entry per line, but blank lines are ignored, so the entries
    # are simply the remaining whitespace-separated tokens in groups.
    tokens = " ".join(lines[pos:]).split()

    try:
        if fmt == "coordinate":
            if len(size) != 3:
                raise MatrixMarketError("coordinate size line needs rows cols nnz")
            rows, cols, nnz = (int(t) for t in size)
            data = _read_coordinate(tokens, rows, cols, nnz, field, symmetry)
        else:
            if len(size) != 2:
                raise MatrixMarketError("array size line needs rows cols")
            rows, cols = (int(t) for t in size)
            data = _read_array(tokens, rows, cols, symmetry)
    except (ValueError, IndexError) as exc:
        if isinstance(exc, MatrixMarketError):
            raise
        raise MatrixMarketError(f"malformed matrix data: {exc}") from exc
    return Matrix(data)


def _read_coordinate(
    tokens: list[str], rows: int, cols: int, nnz: int, field: str, symmetry: str
) -> list[list[float]]:
    data = [[0.0] * cols for _ in range(rows)]
    width = 2 if field == "pattern" else 3
    if len(tokens) < nnz * width:
        raise MatrixMarketError("fewer entries than the size line promises")
    mirror = 0.0 if symmetry == "general" else (1.0 if symmetry == "symmetric" else -1.0)
    for e in range(nnz):
        base = e * width
        i = int(tokens[base]) - 1
        j = int(tokens[base + 1]) - 1
        value = 1.0 if field == "pattern" else float(tokens[base + 2])
        data[i][j] = value
        if symmetry != "general" and i != j:
            data[j][i] = mirror * value
    return data


def _read_array(tokens: list[str], rows: int, cols: int, symmetry: str) -> list[list[float]]:
    data = [[0.0] * cols for _ in range(rows)]
    pos = 0
    if symmetry == "general":
        if len(tokens) < rows * cols:
            raise MatrixMarketError("fewer values than the size line promises")
        for j in range(cols):
            for i in range(rows):
                data[i][j] = float(tokens[pos])
                pos += 1
        return data
    if rows != cols:
        raise MatrixMarketError("symmetric storage requires a square matrix")
    sign = 1.0 if symmetry == "symmetric" else -1.0
    first = 0 if symmetry == "symmetric" else 1  # skew-symmetric omits the diagonal
    for j in range(cols):
        for i in range(j + first, rows):
            value = float(tokens[pos])
            pos += 1
            data[i][j] = value
            if i != j:
                data[j][i] = sign * value
    return data


def read_matrix(path: PathLike) -> Matrix:
    """Read a Matrix Market file from ``path``."""
    with open(path, encoding="utf-8") as handle:
        return parse_matrix(handle.read())


def format_value(value: float) -> str:
    """Format like ``printf("%.10e")``, with negative zero written as zero."""
    if value == 0.0:
        value = 0.0
    return "%.10e" % value


def format_matrix(matrix: Matrix) -> str:
    """Render ``matrix`` as ``array real general`` text (column-major)."""
    lines = ["%%MatrixMarket matrix array real general", f"{matrix.rows} {matrix.cols}"]
    for col in matrix.to_columns():
        lines.extend(format_value(v) for v in col)
    return "\n".join(lines) + "\n"


def write_matrix(matrix: Matrix, path: PathLike) -> None:
    """Write ``matrix`` to ``path`` in the fixed output form."""
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(format_matrix(matrix))
