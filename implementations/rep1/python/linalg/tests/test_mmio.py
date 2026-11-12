import pytest

from linalg import Matrix, MatrixMarketError, format_matrix, parse_matrix, read_matrix, write_matrix
from linalg.mmio import format_value

HEAD = "%%MatrixMarket matrix "


def test_array_general_is_column_major():
    m = parse_matrix(HEAD + "array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n")
    assert m == Matrix([[1, 2], [3, 4]])


def test_array_symmetric_lower_triangle():
    m = parse_matrix(HEAD + "array real symmetric\n2 2\n4.0\n2.0\n5.0\n")
    assert m == Matrix([[4, 2], [2, 5]])


def test_array_skew_symmetric():
    m = parse_matrix(HEAD + "array real skew-symmetric\n3 3\n1\n2\n3\n")
    assert m == Matrix([[0, -1, -2], [1, 0, -3], [2, 3, 0]])


def test_coordinate_general_with_comments_and_blank_lines():
    text = HEAD + "COORDINATE Real General\n% a comment\n\n  \n2 2 2\n1 1 0.5\n\n2 2 -1.5\n"
    assert parse_matrix(text) == Matrix([[0.5, 0], [0, -1.5]])


def test_coordinate_symmetric_and_skew():
    sym = parse_matrix(HEAD + "coordinate real symmetric\n3 3 3\n1 1 2\n2 1 -1\n3 2 5\n")
    assert sym == Matrix([[2, -1, 0], [-1, 0, 5], [0, 5, 0]])
    skew = parse_matrix(HEAD + "coordinate integer skew-symmetric\n2 2 1\n2 1 7\n")
    assert skew == Matrix([[0, -7], [7, 0]])


def test_coordinate_pattern():
    m = parse_matrix(HEAD + "coordinate pattern general\n2 3 2\n1 3\n2 1\n")
    assert m == Matrix([[0, 0, 1], [1, 0, 0]])


def test_exponent_forms():
    m = parse_matrix(HEAD + "array real general\n1 3\n3.0e-7\n1.0E+03\n-2.5\n")
    assert m == Matrix([[3e-7, 1e3, -2.5]])


def test_bad_banner():
    with pytest.raises(MatrixMarketError):
        parse_matrix("hello\n1 1\n1\n")


@pytest.mark.parametrize(
    "value, text",
    [
        (1.2345678901, "1.2345678901e+00"),
        (-0.007, "-7.0000000000e-03"),
        (40015.422479, "4.0015422479e+04"),
        (-0.0, "0.0000000000e+00"),
        (1e100, "1.0000000000e+100"),
    ],
)
def test_format_value(value, text):
    assert format_value(value) == text


def test_format_matrix_column_major_with_trailing_newline():
    text = format_matrix(Matrix([[1, 2], [3, 4]]))
    assert text == (
        "%%MatrixMarket matrix array real general\n2 2\n"
        "1.0000000000e+00\n3.0000000000e+00\n2.0000000000e+00\n4.0000000000e+00\n"
    )


def test_write_read_roundtrip(tmp_path):
    m = Matrix([[1.5, -2.25], [0.0, 1e-5]])
    path = tmp_path / "m.mtx"
    write_matrix(m, path)
    assert read_matrix(path) == m
