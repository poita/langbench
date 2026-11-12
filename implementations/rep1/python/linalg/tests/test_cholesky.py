import pytest

from conftest import assert_matrix_close, matmul
from linalg import (Matrix, NotPositiveDefinite, NotSquare, NotSymmetric, cholesky)


def test_spec_example():
    assert cholesky(Matrix([[4, 2], [2, 5]])) == Matrix([[2, 0], [1, 2]])


def test_reconstructs_spd(rand):
    b = rand(6, 6)
    a = matmul(b, b.T)
    a = Matrix([[a[i, j] + (6.0 if i == j else 0.0) for j in range(6)] for i in range(6)])
    low = cholesky(a)
    assert_matrix_close(matmul(low, low.T), a)
    assert all(low[i, j] == 0.0 for i in range(6) for j in range(i + 1, 6))


def test_errors_in_documented_order():
    with pytest.raises(NotSquare):
        cholesky(Matrix([[1, 2, 3], [4, 5, 6]]))
    with pytest.raises(NotSymmetric):
        cholesky(Matrix([[1, 2], [3, 4]]))
    with pytest.raises(NotPositiveDefinite):
        cholesky(Matrix([[1, 2], [2, 1]]))
    with pytest.raises(NotPositiveDefinite):
        cholesky(Matrix([[0, 0], [0, 0]]))
