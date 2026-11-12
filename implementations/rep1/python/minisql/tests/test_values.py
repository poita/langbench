import pytest

from minisql.like import like_match
from minisql.values import Real, average, compare, format_value, truth


def test_total_order():
    order = [None, -5, 0, 7, Real(750), "", "a", "ab", "b"]
    for i, a in enumerate(order):
        for j, b in enumerate(order):
            assert (compare(a, b) > 0) - (compare(a, b) < 0) == (i > j) - (i < j)


def test_text_is_case_sensitive_and_numbers_below_text():
    assert compare("B", "a") < 0
    assert compare(100, "0") < 0


def test_int_equals_real_by_value():
    assert compare(2, Real(200)) == 0


@pytest.mark.parametrize(
    "total,count,expected",
    [(3, 2, "1.50"), (4, 3, "1.33"), (36, 8, "4.50"), (-3, 2, "-1.50"),
     (9, 8, "1.13"), (-9, 8, "-1.13"), (-1, 201, "0.00"), (80, 3, "26.67")],
)
def test_average_rounds_half_away_from_zero(total, count, expected):
    assert format_value(average(total, count)) == expected


def test_format_value():
    assert [format_value(v) for v in (None, 0, -3, "x")] == ["NULL", "0", "-3", "x"]


def test_truth():
    assert truth(None) is None
    assert truth(0) is False and truth(-2) is True
    assert truth(Real(0)) is False and truth(Real(5)) is True


@pytest.mark.parametrize(
    "text,pattern,expected",
    [
        ("APPLE", "apple", True),
        ("É", "é", False),
        ("abc", "a%", True),
        ("abc", "%", True),
        ("", "%", True),
        ("", "_", False),
        ("abc", "a_c", True),
        ("abc", "a_", False),
        ("abcabc", "%bc", True),
        ("abcabd", "%bc", False),
        ("aXbXc", "a%b%c", True),
        ("mississippi", "m%iss%ppi", True),
        ("mississippi", "m%iss%ppx", False),
        ("a%b", "a%b", True),
    ],
)
def test_like_match(text, pattern, expected):
    assert like_match(text, pattern) is expected


def test_like_is_not_exponential():
    assert not like_match("a" * 5000, "%a" * 40 + "b")
