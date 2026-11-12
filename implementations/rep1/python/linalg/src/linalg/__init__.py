"""linalg: dense real linear algebra in pure Python.

Public API
----------
Data and I/O
    :class:`Matrix`, :func:`read_matrix`, :func:`parse_matrix`,
    :func:`write_matrix`, :func:`format_matrix`
Arithmetic and norms
    :func:`add`, :func:`mul`, :func:`transpose`, :func:`norm1`,
    :func:`norminf`, :func:`normfro`
Factorisations and solvers
    :func:`lu_factor` (:class:`LU`), :func:`det`, :func:`solve`,
    :func:`inv`, :func:`qr`, :func:`lstsq`, :func:`cholesky`,
    :func:`eigh`, :func:`svd`, :func:`cond`
Errors
    :class:`LinalgError` and its subclasses, each with a ``code``.
"""

from .arithmetic import add, mul, transpose
from .llt import cholesky
from .eigen import eigh
from .errors import (
    DimensionMismatch,
    LinalgError,
    NotPositiveDefinite,
    NotSquare,
    NotSymmetric,
    Singular,
)
from .lu import LU, det, inv, lu_factor, lu_solve, solve
from .matrix import Matrix
from .mmio import MatrixMarketError, format_matrix, parse_matrix, read_matrix, write_matrix
from .norms import norm1, norminf, normfro
from .householder import lstsq, qr
from .jacobi_svd import cond, singular_values, svd

__version__ = "1.0.0"

__all__ = [
    "DimensionMismatch",
    "LU",
    "LinalgError",
    "Matrix",
    "MatrixMarketError",
    "NotPositiveDefinite",
    "NotSquare",
    "NotSymmetric",
    "Singular",
    "add",
    "cholesky",
    "cond",
    "det",
    "eigh",
    "format_matrix",
    "inv",
    "lstsq",
    "lu_factor",
    "lu_solve",
    "mul",
    "norm1",
    "norminf",
    "normfro",
    "parse_matrix",
    "qr",
    "read_matrix",
    "singular_values",
    "solve",
    "svd",
    "transpose",
    "write_matrix",
]
