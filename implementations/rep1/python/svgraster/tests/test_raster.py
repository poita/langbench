import math

from svgraster.raster import Canvas, rasterize


def coverage(runs, w, h):
    grid = [[0.0] * w for _ in range(h)]
    for row, x0, covs in runs:
        for i, c in enumerate(covs):
            grid[row][x0 + i] = c
    return grid


def test_fractional_rect():
    runs = rasterize([[(1, 1), (4.5, 1), (4.5, 3), (1, 3)]], False, 8, 4)
    g = coverage(runs, 8, 4)
    assert g[1] == [0, 1, 1, 1, 0.5, 0, 0, 0]
    assert g[0] == [0] * 8 and g[3] == [0] * 8


def test_clipping_outside_canvas():
    runs = rasterize([[(-50, -50), (50, -50), (50, 50), (-50, 50)]], False, 4, 3)
    assert all(c == 1.0 for g in coverage(runs, 4, 3) for c in g)


def test_fill_rules_on_overlap():
    outer = [(0, 0), (6, 0), (6, 6), (0, 6)]
    inner = [(2, 2), (4, 2), (4, 4), (2, 4)]
    nz = coverage(rasterize([outer, inner], False, 6, 6), 6, 6)
    eo = coverage(rasterize([outer, inner], True, 6, 6), 6, 6)
    assert nz[3][3] == 1.0 and eo[3][3] == 0.0
    # opposite orientation cancels under non-zero
    hole = coverage(rasterize([outer, inner[::-1]], False, 6, 6), 6, 6)
    assert hole[3][3] == 0.0


def test_triangle_area():
    runs = rasterize([[(0, 0), (16, 0), (0, 16)]], False, 16, 16)
    total = sum(sum(c) for _, _, c in runs)
    assert math.isclose(total, 128, abs_tol=0.5)


def test_canvas_paint_and_output():
    cv = Canvas(2, 1)
    cv.paint([(0, 0, [1.0, 0.5])], (0.0, 0.0, 1.0), 1.0)
    assert cv.to_rgb_bytes() == bytes([0, 0, 255, 128, 128, 255])


def test_group_composite():
    top = Canvas(1, 1)
    top.paint([(0, 0, [1.0])], (1.0, 0.0, 0.0), 1.0)
    base = Canvas(1, 1)
    base.composite(top, 0.5)
    assert base.to_rgb_bytes() == bytes([255, 128, 128])
