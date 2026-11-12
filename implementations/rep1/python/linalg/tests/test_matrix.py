import pytest

from linalg import Matrix, add, mul, norm1, norminf, normfro, transpose, DimensionMismatch


def test_construction_and_shape():
    m = Matrix([[1, 2, 3], [4, 5, 6]])
    assert m.shape == (2, 3)
    assert m[1, 2] == 6.0
    assert m.column(1) == [2.0, 5.0]
    assert m.to_columns() == [[1.0, 4.0], [2.0, 5.0], [3.0, 6.0]]


def test_rejects_ragged_and_empty():
    with pytest.raises(ValueError):
        Matrix([[1.0], [1.0, 2.0]])
    with pytest.raises(ValueError):
        Matrix([])


def test_does_not_alias_input():
    rows = [[1.0, 2.0]]
    m = Matrix(rows)
    rows[0][0] = 9.0
    assert m[0, 0] == 1.0


def test_symmetry_is_exact():
    assert Matrix([[1, 2], [2, 3]]).is_symmetric()
    assert not Matrix([[1, 2], [2 + 1e-15, 3]]).is_symmetric()
    assert not Matrix([[1, 2, 3]]).is_symmetric()


def test_add_mul_transpose():
    a = Matrix([[1, 2], [3, 4]])
    b = Matrix([[0.5, 0], [0, -1.5]])
    assert add(a, b) == Matrix([[1.5, 2], [3, 2.5]])
    assert mul(a, b) == Matrix([[0.5, -3], [1.5, -6]])
    assert transpose(Matrix([[1, 2, 3]])) == Matrix([[1], [2], [3]])


def test_shape_errors():
    with pytest.raises(DimensionMismatch):
        add(Matrix([[1, 2]]), Matrix([[1], [2]]))
    with pytest.raises(DimensionMismatch):
        mul(Matrix([[1, 2]]), Matrix([[1, 2]]))


def test_mul_uses_plain_running_sum():
    # Compensated summation would give 1.0; a plain running sum gives 0.0.
    a = Matrix([[1e16, 1.0, -1e16]])
    b = Matrix([[1.0], [1.0], [1.0]])
    assert mul(a, b)[0, 0] == 0.0


def test_norms():
    a = Matrix([[1, -2], [-3, 4]])
    assert norm1(a) == 6.0
    assert norminf(a) == 7.0
    assert normfro(a) == pytest.approx(30 ** 0.5)
