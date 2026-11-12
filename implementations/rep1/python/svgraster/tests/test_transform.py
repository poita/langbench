import math

from svgraster.transform import apply, parse_transform


def close(p, q):
    return math.isclose(p[0], q[0], abs_tol=1e-9) and math.isclose(p[1], q[1], abs_tol=1e-9)


def test_composition_order():
    m = parse_transform("translate(10 0) scale(2)")
    assert close(apply(m, 1, 1), (12, 2))


def test_rotate_about_point():
    m = parse_transform("rotate(90 10 10)")
    assert close(apply(m, 20, 10), (10, 20))


def test_skew_and_skipped():
    assert close(apply(parse_transform("skewX(45)"), 0, 1), (1, 1))
    assert parse_transform("bogus(1) translate()") == (1, 0, 0, 1, 0, 0)
    assert close(apply(parse_transform("matrix(1,0,0,1,5,6)"), 0, 0), (5, 6))
