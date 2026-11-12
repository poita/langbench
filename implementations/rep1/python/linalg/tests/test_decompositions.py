import pytest

from conftest import assert_matrix_close, matmul
from linalg import (Matrix, NotSquare, NotSymmetric, Singular, cond, eigh, singular_values, svd)


def diag(values):
    n = len(values)
    return Matrix([[values[i] if i == j else 0.0 for j in range(n)] for i in range(n)])


def symmetric(rand, n):
    b = rand(n, n)
    return Matrix([[b[i, j] + b[j, i] for j in range(n)] for i in range(n)])


def test_eig_spec_example():
    w, v = eigh(Matrix([[2, 1], [1, 3]]))
    assert w == pytest.approx([(5 - 5 ** 0.5) / 2, (5 + 5 ** 0.5) / 2])
    assert v.column(0) == pytest.approx([0.8506508084, -0.5257311121])
    assert v.column(1) == pytest.approx([0.5257311121, 0.8506508084])


def test_eig_random(rand):
    a = symmetric(rand, 8)
    w, v = eigh(a)
    assert w == sorted(w)
    assert_matrix_close(matmul(matmul(v, diag(w)), v.T), a, tol=1e-10)
    assert_matrix_close(matmul(v.T, v), Matrix.identity(8), tol=1e-10)
    for j in range(8):
        col = v.column(j)
        biggest = max(range(8), key=lambda i: abs(col[i]))
        assert col[biggest] > 0


def test_eig_errors():
    with pytest.raises(NotSquare):
        eigh(Matrix([[1, 2, 3]]))
    with pytest.raises(NotSymmetric):
        eigh(Matrix([[1, 2], [3, 4]]))


def test_eig_diagonal_input():
    w, v = eigh(diag([3.0, 1.0, 2.0]))
    assert w == [1.0, 2.0, 3.0]
    assert v == Matrix([[0, 0, 1], [1, 0, 0], [0, 1, 0]])


@pytest.mark.parametrize("shape", [(6, 4), (4, 6), (5, 5), (1, 4), (4, 1), (1, 1)])
def test_svd_reconstructs(rand, shape):
    m, n = shape
    a = rand(m, n)
    u, s, v = svd(a)
    k = min(m, n)
    assert u.shape == (m, k) and v.shape == (n, k) and len(s) == k
    assert all(x >= 0 for x in s) and s == sorted(s, reverse=True)
    assert_matrix_close(matmul(matmul(u, diag(s)), v.T), a, tol=1e-10)
    assert_matrix_close(matmul(u.T, u), Matrix.identity(k), tol=1e-10)
    assert_matrix_close(matmul(v.T, v), Matrix.identity(k), tol=1e-10)
    for j in range(k):
        col = u.column(j)
        assert col[max(range(m), key=lambda i: abs(col[i]))] > 0


def test_singular_values_of_diagonal():
    assert singular_values(diag([1.0, -4.0, 2.0])) == pytest.approx([4.0, 2.0, 1.0])


def test_cond():
    assert cond(diag([2.0, 8.0])) == pytest.approx(4.0)
    assert cond(Matrix([[5.0]])) == 1.0
    with pytest.raises(Singular):
        cond(Matrix([[1, 1], [0, 0]]))
