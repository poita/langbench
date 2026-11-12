import pytest

from conftest import assert_matrix_close, matmul
from linalg import (DimensionMismatch, Matrix, NotSquare, Singular, det, inv, lu_factor,
                    solve)


def test_lu_reconstructs(rand):
    a = rand(6, 6)
    f = lu_factor(a)
    assert_matrix_close(matmul(f.P, a), matmul(f.L, f.U))
    assert all(abs(x) <= 1.0 for row in f.L.to_rows() for x in row)


def test_pivot_tie_takes_smallest_index():
    f = lu_factor(Matrix([[1, 2], [-1, 5]]))
    assert f.perm == (0, 1) and f.swaps == 0


def test_permutation_convention():
    f = lu_factor(Matrix([[1, 2], [3, 4]]))
    assert f.perm == (1, 0)
    assert f.P == Matrix([[0, 1], [1, 0]])
    assert f.U == Matrix([[3, 4], [0, 2 - (1 / 3) * 4]])


def test_det_spec_example_and_sign():
    assert det(Matrix([[1, 2], [3, 4]])) == pytest.approx(-2.0)
    assert det(Matrix([[2, 0], [0, 3]])) == 6.0
    assert det(Matrix([[1, 2], [2, 4]])) == 0.0


def test_singular_and_shape_errors():
    with pytest.raises(Singular):
        lu_factor(Matrix([[0, 1], [0, 2]]))
    with pytest.raises(NotSquare):
        inv(Matrix([[1, 2, 3], [4, 5, 6]]))
    with pytest.raises(NotSquare):
        det(Matrix([[1, 2, 3]]))


def test_solve_checks_square_before_rhs():
    with pytest.raises(NotSquare):
        solve(Matrix([[1, 2, 3], [4, 5, 6]]), Matrix([[1], [2], [3]]))
    with pytest.raises(DimensionMismatch):
        solve(Matrix.identity(2), Matrix([[1], [2], [3]]))


def test_solve_and_inverse(rand):
    a, b = rand(7, 7), rand(7, 3)
    assert_matrix_close(matmul(a, solve(a, b)), b)
    assert_matrix_close(matmul(a, inv(a)), Matrix.identity(7))
