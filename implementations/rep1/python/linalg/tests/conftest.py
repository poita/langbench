import random

import pytest

from linalg import Matrix


def close(a, b, tol=1e-9):
    return abs(a - b) <= tol * max(1.0, abs(a), abs(b))


def assert_matrix_close(a: Matrix, b: Matrix, tol=1e-9):
    assert a.shape == b.shape
    for ra, rb in zip(a.to_rows(), b.to_rows()):
        for x, y in zip(ra, rb):
            assert close(x, y, tol), (a, b)


def matmul(a: Matrix, b: Matrix) -> Matrix:
    """Independent reference product (test-only)."""
    ar, bc = a.to_rows(), b.to_columns()
    return Matrix([sum(x * y for x, y in zip(r, c)) for c in bc] for r in ar)


@pytest.fixture
def rng():
    return random.Random(12345)


def random_matrix(rng, m, n):
    return Matrix([[rng.uniform(-1, 1) for _ in range(n)] for _ in range(m)])


@pytest.fixture
def rand(rng):
    return lambda m, n: random_matrix(rng, m, n)
