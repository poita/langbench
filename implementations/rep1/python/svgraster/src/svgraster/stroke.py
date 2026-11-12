"""Stroke outlining (SPEC §8.2).

The stroke region is the union of simple pieces (segment rectangles, join
pieces and cap pieces).  Each piece is returned as a polygon oriented with a
positive signed area, so filling them all together with the non-zero rule
yields the union.
"""

from __future__ import annotations

import math

from .path import Subpath

__all__ = ["stroke_polygons", "arc_points"]

Point = tuple[float, float]
Polygon = list[Point]


def arc_points(cx: float, cy: float, r: float, a0: float, sweep: float, tol: float) -> Polygon:
    """Points of a circular arc from angle *a0* through *sweep* radians.

    Both end points are included; the polyline stays within *tol* of the arc.
    """
    if r <= tol:
        step = math.pi / 2
    else:
        step = 2.0 * math.acos(1.0 - tol / r)
    n = max(1, math.ceil(abs(sweep) / step))
    return [
        (cx + r * math.cos(a0 + sweep * i / n), cy + r * math.sin(a0 + sweep * i / n))
        for i in range(n + 1)
    ]


def _oriented(poly: Polygon) -> Polygon | None:
    """Return *poly* with positive signed area, or ``None`` if it has none."""
    area = 0.0
    px, py = poly[-1]
    for x, y in poly:
        area += px * y - x * py
        px, py = x, y
    if area == 0.0 or area != area:
        return None
    return poly if area > 0 else poly[::-1]


def _dedupe(points: list[Point], closed: bool) -> list[Point]:
    out: list[Point] = []
    for p in points:
        if not out or p != out[-1]:
            out.append(p)
    if closed and len(out) > 1 and out[-1] == out[0]:
        out.pop()
    return out


def stroke_polygons(
    subpaths: list[Subpath], width: float, cap: str, join: str,
    miterlimit: float, tol: float,
) -> list[Polygon]:
    """Build the stroke pieces for flattened *subpaths*.

    *width* is the stroke width, *cap* one of ``butt``/``round``/``square``,
    *join* one of ``miter``/``round``/``bevel``; *tol* is the flattening
    tolerance for round joins and caps, in the same units as the points.
    """
    r = width / 2.0
    miterlimit = max(1.0, miterlimit)
    pieces: list[Polygon] = []

    def add(poly: Polygon) -> None:
        o = _oriented(poly)
        if o is not None:
            pieces.append(o)

    for sp in subpaths:
        pts = _dedupe(sp.points, sp.closed)
        n = len(pts)
        if n == 0:
            continue
        if n == 1:
            x, y = pts[0]
            if cap == "round":
                add(arc_points(x, y, r, 0.0, 2 * math.pi, tol)[:-1])
            elif cap == "square":
                add([(x - r, y - r), (x + r, y - r), (x + r, y + r), (x - r, y + r)])
            continue
        nseg = n if sp.closed else n - 1
        dirs: list[Point] = []
        for i in range(nseg):
            ax, ay = pts[i]
            bx, by = pts[(i + 1) % n]
            dx, dy = bx - ax, by - ay
            length = math.hypot(dx, dy)
            dirs.append((dx / length, dy / length))
            nx, ny = -dy / length * r, dx / length * r
            add([(ax + nx, ay + ny), (bx + nx, by + ny), (bx - nx, by - ny), (ax - nx, ay - ny)])
        # joins
        joint_range = range(nseg) if sp.closed else range(1, nseg)
        for i in joint_range:
            d0 = dirs[i - 1]
            d1 = dirs[i]
            px, py = pts[i]
            _add_join(add, px, py, d0, d1, r, join, miterlimit, tol)
        # caps
        if not sp.closed and cap != "butt":
            for (px, py), u in ((pts[0], (-dirs[0][0], -dirs[0][1])),
                                (pts[-1], dirs[-1])):
                nx, ny = -u[1] * r, u[0] * r
                if cap == "square":
                    add([(px + nx, py + ny), (px + nx + u[0] * r, py + ny + u[1] * r),
                         (px - nx + u[0] * r, py - ny + u[1] * r), (px - nx, py - ny)])
                else:  # round: half disc on the u side
                    a0 = math.atan2(ny, nx)
                    add(arc_points(px, py, r, a0, -math.pi, tol))
    return pieces


def _add_join(add, px: float, py: float, d0: Point, d1: Point, r: float,
              join: str, miterlimit: float, tol: float) -> None:
    cross = d0[0] * d1[1] - d0[1] * d1[0]
    dot = d0[0] * d1[0] + d0[1] * d1[1]
    if cross == 0 and dot > 0:
        return
    s = 1.0 if cross > 0 else -1.0
    ax, ay = px + s * d0[1] * r, py - s * d0[0] * r
    bx, by = px + s * d1[1] * r, py - s * d1[0] * r
    if join == "round":
        a0 = math.atan2(ay - py, ax - px)
        if cross == 0:
            sweep = s * math.pi
        else:
            sweep = math.atan2((ax - px) * (by - py) - (ay - py) * (bx - px),
                               (ax - px) * (bx - px) + (ay - py) * (by - py))
        add([(px, py)] + arc_points(px, py, r, a0, sweep, tol))
        return
    if join == "miter" and dot > -1 and cross != 0:
        ratio = 1.0 / math.sqrt((1.0 + dot) / 2.0)
        if ratio <= miterlimit:
            k = 1.0 / (1.0 + dot)
            mx = px + ((ax - px) + (bx - px)) * k
            my = py + ((ay - py) + (by - py)) * k
            add([(px, py), (ax, ay), (mx, my), (bx, by)])
            return
    add([(px, py), (ax, ay), (bx, by)])
