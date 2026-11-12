import pytest

from conftest import assert_matrix_close, matmul
from linalg import DimensionMismatch, Matrix, Singular, lstsq, qr


def test_qr_reconstructs_and_is_normalised(rand):
    a = rand(8, 5)
    q, r = qr(a)
    assert q.shape == (8, 5) and r.shape == (5, 5)
    assert_matrix_close(matmul(q, r), a)
    assert_matrix_close(matmul(q.T, q), Matrix.identity(5))
    for i in range(5):
        assert r[i, i] >= 0.0
        assert all(r[i, j] == 0.0 for j in range(i))


def test_qr_sign_normalisation_example():
    q, r = qr(Matrix([[3], [4]]))
    assert r[0, 0] == pytest.approx(5.0)
    assert q.column(0) == pytest.approx([0.6, 0.8])


def test_qr_handles_zero_column():
    q, r = qr(Matrix([[0, 1], [0, 2], [0, 3]]))
    assert r[0, 0] == 0.0
    assert_matrix_close(matmul(q, r), Matrix([[0, 1], [0, 2], [0, 3]]))


def test_qr_rejects_wide():
    with pytest.raises(DimensionMismatch):
        qr(Matrix([[1, 2, 3]]))


def test_lstsq_fits_a_line():
    a = Matrix([[1, 0], [1, 1], [1, 2], [1, 3]])
    b = Matrix([[1], [3], [5], [7]])
    assert_matrix_close(lstsq(a, b), Matrix([[1], [2]]))


def test_lstsq_normal_equations(rand):
    a, b = rand(9, 4), rand(9, 2)
    x = lstsq(a, b)
    residual = matmul(a, x)
    diff = Matrix([[p - q for p, q in zip(rp, rq)] for rp, rq in zip(residual.to_rows(), b.to_rows())])
    assert_matrix_close(matmul(a.T, diff), Matrix.zeros(4, 2), tol=1e-9)


def test_lstsq_errors():
    with pytest.raises(DimensionMismatch):
        lstsq(Matrix([[1, 2, 3]]), Matrix([[1]]))
    with pytest.raises(DimensionMismatch):
        lstsq(Matrix([[1], [2]]), Matrix([[1]]))
    with pytest.raises(Singular):
        lstsq(Matrix([[1, 0], [2, 0], [3, 0]]), Matrix([[1], [2], [3]]))
