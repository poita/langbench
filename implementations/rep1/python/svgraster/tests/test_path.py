import math

from svgraster.path import (arc_to_cubics, ellipse_path, flatten, flatten_cubic,
                            parse_path_data, rect_path)


def test_basic_commands_and_implicit_lineto():
    p = parse_path_data("M10,10 20,40 40,10z")
    assert p == [("M", 10, 10), ("L", 20, 40), ("L", 40, 10), ("Z",)]


def test_relative_and_hv():
    p = parse_path_data("m1 2 h3 v4 l-1 -1")
    assert p == [("M", 1, 2), ("L", 4, 2), ("L", 4, 6), ("L", 3, 5)]


def test_number_after_z_stops_parse():
    assert parse_path_data("M0 0 L1 0 Z 5 5 L9 9") == [("M", 0, 0), ("L", 1, 0), ("Z",)]


def test_garbage_stops_parse():
    assert parse_path_data("M0 0 L1 1 bogus L5 5") == [("M", 0, 0), ("L", 1, 1)]
    assert parse_path_data("M0 0 L1") == [("M", 0, 0)]


def test_drawing_after_z_starts_new_subpath():
    p = parse_path_data("M1 1 L5 1 Z L9 9")
    assert p[-2:] == [("M", 1, 1), ("L", 9, 9)]


def test_quadratic_is_converted_to_cubic():
    (_, seg) = parse_path_data("M0 0 Q 3 3 6 0")
    assert seg == ("C", 2.0, 2.0, 4.0, 2.0, 6.0, 0.0)


def test_smooth_reflection():
    p = parse_path_data("M0 0 C 0 1 1 2 2 2 S 4 3 5 2")
    assert p[2][1:3] == (3, 2)


def test_arc_flags_are_single_characters():
    p = parse_path_data("M0 0 a5 5 0 0110 10")
    assert p[-1][-2:] == (10, 10)


def test_arc_degenerate_cases():
    assert parse_path_data("M1 1 A5 5 0 0 1 1 1") == [("M", 1, 1)]
    assert parse_path_data("M0 0 A0 5 0 0 1 4 4") == [("M", 0, 0), ("L", 4, 4)]


def test_arc_cubics_end_points_and_radius():
    segs = arc_to_cubics(10, 0, 10, 10, 0, False, True, 0, 10)
    assert segs[-1][-2:] == (0, 10)
    flat = flatten([("M", 10, 0)] + [("C",) + s for s in segs], None, 0.001)[0].points
    for x, y in flat:
        assert abs(math.hypot(x, y) - 10) < 0.01


def test_flatten_cubic_tolerance():
    p0, p1, p2, p3 = (0, 0), (0, 10), (10, 10), (10, 0)
    pts = [p0] + flatten_cubic(p0, p1, p2, p3, 0.01)
    assert pts[-1] == p3 and len(pts) > 5
    # the midpoint of the curve must be near the polyline
    mid = (5.0, 7.5)
    best = min(math.dist(mid, q) for q in pts)
    assert best < 0.5


def test_rect_shapes():
    assert rect_path(0, 0, 0, 5, None, None) == []
    assert len(rect_path(0, 0, 4, 4, None, None)) == 5
    assert rect_path(0, 0, 10, 10, 20, None)[0] == ("M", 5, 0)
    assert ellipse_path(0, 0, 0, 3) == []


def test_flatten_lone_move_is_dropped():
    assert flatten(parse_path_data("M1 1 M2 2 L3 3")) [0].points[0] == (2, 2)
    assert len(flatten(parse_path_data("M1 1 M2 2 L3 3"))) == 1
    assert len(flatten(parse_path_data("M5 5 Z"))) == 1
