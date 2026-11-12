from svgraster.path import Subpath
from svgraster.stroke import stroke_polygons


def area(poly):
    a = 0.0
    px, py = poly[-1]
    for x, y in poly:
        a += px * y - x * py
        px, py = x, y
    return a / 2


def test_segment_rectangle_only_for_butt():
    polys = stroke_polygons([Subpath([(0, 0), (10, 0)], False)], 2, "butt", "miter", 4, 0.01)
    assert len(polys) == 1 and area(polys[0]) == 20


def test_square_cap_and_pieces_oriented():
    polys = stroke_polygons([Subpath([(0, 0), (10, 0)], False)], 2, "square", "miter", 4, 0.01)
    assert len(polys) == 3 and all(area(p) > 0 for p in polys)


def test_single_point_caps():
    sp = [Subpath([(5, 5), (5, 5)], False)]
    assert stroke_polygons(sp, 2, "butt", "miter", 4, 0.01) == []
    (sq,) = stroke_polygons(sp, 2, "square", "miter", 4, 0.01)
    assert area(sq) == 4
    (disc,) = stroke_polygons(sp, 2, "round", "miter", 4, 0.01)
    assert abs(area(disc) - 3.14159) < 0.05


def test_miter_limit_falls_back_to_bevel():
    corner = [Subpath([(0, 0), (10, 0), (0, 1)], False)]  # very sharp turn
    miter = stroke_polygons(corner, 2, "butt", "miter", 100, 0.01)
    bevel = stroke_polygons(corner, 2, "butt", "miter", 1, 0.01)
    assert len(miter[-1]) == 4 and len(bevel[-1]) == 3


def test_collinear_continuation_has_no_join():
    polys = stroke_polygons([Subpath([(0, 0), (5, 0), (10, 0)], False)], 2, "butt", "round", 4, 0.01)
    assert len(polys) == 2
