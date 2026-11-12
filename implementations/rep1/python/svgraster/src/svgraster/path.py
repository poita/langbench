"""Paths: path-data parsing, shapes as paths, arcs and curve flattening.

A *path* is a list of segment tuples using absolute coordinates:

* ``("M", x, y)``
* ``("L", x, y)``
* ``("C", x1, y1, x2, y2, x, y)``
* ``("Z",)``

Flattening turns a path into :class:`Subpath` objects (polylines).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .transform import Matrix, apply
from .values import NUMBER_RE, parse_length, parse_number_list

__all__ = [
    "Segment",
    "Path",
    "Subpath",
    "parse_path_data",
    "arc_to_cubics",
    "rect_path",
    "ellipse_path",
    "line_path",
    "poly_path",
    "flatten",
    "flatten_cubic",
]

Segment = tuple
Path = list[Segment]

_FLAT_TOL = 0.01
_MAX_STEPS = 1000


@dataclass
class Subpath:
    """A flattened subpath."""

    points: list[tuple[float, float]]
    closed: bool


# --------------------------------------------------------------------------
# arcs

def arc_to_cubics(
    x0: float, y0: float, rx: float, ry: float, phi_deg: float,
    large: bool, sweep: bool, x: float, y: float,
) -> list[tuple[float, float, float, float, float, float]]:
    """Convert an SVG elliptical arc to cubic Bézier segments (SVG 1.1 F.6).

    Returns ``[]`` if the end points coincide.  The radii must be non-zero
    (callers turn zero-radius arcs into lines).
    """
    if x0 == x and y0 == y:
        return []
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0:
        raise ValueError("arc radii must be non-zero")
    phi = math.radians(phi_deg)
    cp, sp = math.cos(phi), math.sin(phi)
    dx2, dy2 = (x0 - x) / 2.0, (y0 - y) / 2.0
    x1p = cp * dx2 + sp * dy2
    y1p = -sp * dx2 + cp * dy2
    lam = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx *= s
        ry *= s
    rx2, ry2 = rx * rx, ry * ry
    num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
    den = rx2 * y1p * y1p + ry2 * x1p * x1p
    coef = math.sqrt(max(0.0, num / den)) if den != 0 else 0.0
    if large == sweep:
        coef = -coef
    cxp = coef * rx * y1p / ry
    cyp = -coef * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x0 + x) / 2.0
    cy = sp * cxp + cp * cyp + (y0 + y) / 2.0
    ux, uy = (x1p - cxp) / rx, (y1p - cyp) / ry
    vx, vy = (-x1p - cxp) / rx, (-y1p - cyp) / ry
    theta1 = math.atan2(uy, ux)
    dtheta = math.atan2(vy, vx) - theta1
    two_pi = 2 * math.pi
    if sweep and dtheta < 0:
        dtheta += two_pi
    elif not sweep and dtheta > 0:
        dtheta -= two_pi
    n = max(1, math.ceil(abs(dtheta) / (math.pi / 4)))
    delta = dtheta / n
    k = 4.0 / 3.0 * math.tan(delta / 4.0)
    out = []

    def point(t: float) -> tuple[float, float, float, float]:
        ct, st = math.cos(t), math.sin(t)
        ex, ey = rx * ct, ry * st
        tx, ty = -rx * st, ry * ct
        return (
            cx + cp * ex - sp * ey, cy + sp * ex + cp * ey,
            cp * tx - sp * ty, sp * tx + cp * ty,
        )

    px, py, pdx, pdy = point(theta1)
    px, py = x0, y0
    for i in range(n):
        t1 = theta1 + (i + 1) * delta
        qx, qy, qdx, qdy = point(t1)
        if i == n - 1:
            qx, qy = x, y
        out.append((px + k * pdx, py + k * pdy, qx - k * qdx, qy - k * qdy, qx, qy))
        px, py, pdx, pdy = qx, qy, qdx, qdy
    return out


def _arc_segments(x0, y0, rx, ry, phi, large, sweep, x, y) -> Path:
    if x0 == x and y0 == y:
        return []
    if rx == 0 or ry == 0:
        return [("L", x, y)]
    return [("C",) + c for c in arc_to_cubics(x0, y0, rx, ry, phi, large, sweep, x, y)]


# --------------------------------------------------------------------------
# path data

_CMD_ARGS = {
    "M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0,
}
_NUM_START = frozenset("0123456789+-.")
_SEP = frozenset(" \t\r\n\f,")


def _read_group(d: str, pos: int, cmd: str) -> tuple[list[float], int] | None:
    """Read one parameter group for *cmd* starting at *pos*.

    Returns ``(args, new_pos)`` or ``None`` if the group is incomplete.
    Arc flags are single ``0``/``1`` characters.
    """
    n = len(d)
    args: list[float] = []
    count = _CMD_ARGS[cmd]
    for idx in range(count):
        while pos < n and d[pos] in _SEP:
            pos += 1
        if cmd == "A" and idx in (3, 4):
            if pos < n and d[pos] in "01":
                args.append(float(d[pos]))
                pos += 1
                continue
            return None
        m = NUMBER_RE.match(d, pos)
        if m is None:
            return None
        args.append(float(m.group()))
        pos = m.end()
    return args, pos


def parse_path_data(d: str | None) -> Path:
    """Parse SVG path data (``d`` attribute) into an absolute segment list.

    Parsing stops at the first token that is not the expected kind; the
    commands parsed so far are kept.
    """
    path: Path = []
    if not d:
        return path
    n = len(d)
    pos = 0
    cx = cy = sx = sy = 0.0
    have_point = False
    need_move = False  # a Z was seen: the next drawing command re-opens a subpath
    prev = ""  # previous command letter (upper case)
    ctrl_x = ctrl_y = 0.0  # last control point (cubic or quadratic)

    while True:
        while pos < n and d[pos] in _SEP:
            pos += 1
        if pos >= n:
            break
        letter = d[pos]
        cmd = letter.upper()
        if cmd not in _CMD_ARGS:
            break
        rel = letter != cmd
        pos += 1
        if cmd == "Z":
            if have_point and not need_move:
                path.append(("Z",))
                cx, cy = sx, sy
                need_move = True
            prev = "Z"
            continue
        if not have_point and cmd != "M":
            break
        first = True
        while True:
            if not first:
                i = pos
                while i < n and d[i] in _SEP:
                    i += 1
                if i >= n or d[i] not in _NUM_START:
                    break
            group = _read_group(d, pos, cmd)
            if group is None:
                return path  # incomplete group: stop parsing
            args, pos = group
            first = False
            ox, oy = (cx, cy) if rel else (0.0, 0.0)
            if cmd == "M":
                cx, cy = args[0] + ox, args[1] + oy
                sx, sy = cx, cy
                path.append(("M", cx, cy))
                have_point = True
                need_move = False
                prev = "M"
                cmd = "L"  # implicit repeats are line-tos
                continue
            if need_move:
                path.append(("M", cx, cy))
                need_move = False
            if cmd == "L":
                cx, cy = args[0] + ox, args[1] + oy
                path.append(("L", cx, cy))
            elif cmd == "H":
                cx = args[0] + ox
                path.append(("L", cx, cy))
            elif cmd == "V":
                cy = args[0] + oy
                path.append(("L", cx, cy))
            elif cmd in ("C", "S"):
                if cmd == "C":
                    x1, y1 = args[0] + ox, args[1] + oy
                    x2, y2, x, y = args[2] + ox, args[3] + oy, args[4] + ox, args[5] + oy
                else:
                    if prev in ("C", "S"):
                        x1, y1 = 2 * cx - ctrl_x, 2 * cy - ctrl_y
                    else:
                        x1, y1 = cx, cy
                    x2, y2, x, y = args[0] + ox, args[1] + oy, args[2] + ox, args[3] + oy
                path.append(("C", x1, y1, x2, y2, x, y))
                ctrl_x, ctrl_y = x2, y2
                cx, cy = x, y
            elif cmd in ("Q", "T"):
                if cmd == "Q":
                    qx, qy = args[0] + ox, args[1] + oy
                    x, y = args[2] + ox, args[3] + oy
                else:
                    if prev in ("Q", "T"):
                        qx, qy = 2 * cx - ctrl_x, 2 * cy - ctrl_y
                    else:
                        qx, qy = cx, cy
                    x, y = args[0] + ox, args[1] + oy
                path.append((
                    "C",
                    cx + 2.0 / 3.0 * (qx - cx), cy + 2.0 / 3.0 * (qy - cy),
                    x + 2.0 / 3.0 * (qx - x), y + 2.0 / 3.0 * (qy - y),
                    x, y,
                ))
                ctrl_x, ctrl_y = qx, qy
                cx, cy = x, y
            else:  # "A"
                x, y = args[5] + ox, args[6] + oy
                path.extend(_arc_segments(cx, cy, args[0], args[1], args[2],
                                          args[3] != 0, args[4] != 0, x, y))
                cx, cy = x, y
            prev = cmd
    return path


# --------------------------------------------------------------------------
# shapes

def rect_path(x: float, y: float, w: float, h: float,
              rx: float | None, ry: float | None) -> Path:
    """Path for a ``rect`` (empty if the size is not positive)."""
    if w <= 0 or h <= 0:
        return []
    if rx is None and ry is None:
        rx = ry = 0.0
    elif rx is None:
        rx = ry
    elif ry is None:
        ry = rx
    rx = min(max(rx, 0.0), w / 2.0)
    ry = min(max(ry, 0.0), h / 2.0)
    if rx == 0 or ry == 0:
        return [("M", x, y), ("L", x + w, y), ("L", x + w, y + h), ("L", x, y + h), ("Z",)]
    path: Path = [("M", x + rx, y), ("L", x + w - rx, y)]
    path += _arc_segments(x + w - rx, y, rx, ry, 0, False, True, x + w, y + ry)
    path.append(("L", x + w, y + h - ry))
    path += _arc_segments(x + w, y + h - ry, rx, ry, 0, False, True, x + w - rx, y + h)
    path.append(("L", x + rx, y + h))
    path += _arc_segments(x + rx, y + h, rx, ry, 0, False, True, x, y + h - ry)
    path.append(("L", x, y + ry))
    path += _arc_segments(x, y + ry, rx, ry, 0, False, True, x + rx, y)
    path.append(("Z",))
    return path


def ellipse_path(cx: float, cy: float, rx: float, ry: float) -> Path:
    """Path for a circle/ellipse (empty if a radius is not positive)."""
    if rx <= 0 or ry <= 0:
        return []
    path: Path = [("M", cx + rx, cy)]
    path += _arc_segments(cx + rx, cy, rx, ry, 0, False, True, cx, cy + ry)
    path += _arc_segments(cx, cy + ry, rx, ry, 0, False, True, cx - rx, cy)
    path += _arc_segments(cx - rx, cy, rx, ry, 0, False, True, cx, cy - ry)
    path += _arc_segments(cx, cy - ry, rx, ry, 0, False, True, cx + rx, cy)
    path.append(("Z",))
    return path


def line_path(x1: float, y1: float, x2: float, y2: float) -> Path:
    return [("M", x1, y1), ("L", x2, y2)]


def poly_path(points: str | None, close: bool) -> Path:
    """Path for ``polyline`` / ``polygon`` from a ``points`` attribute."""
    nums = parse_number_list(points)
    n = len(nums) // 2
    if n == 0:
        return []
    path: Path = [("M", nums[0], nums[1])]
    for i in range(1, n):
        path.append(("L", nums[2 * i], nums[2 * i + 1]))
    if close:
        path.append(("Z",))
    return path


# --------------------------------------------------------------------------
# flattening

def flatten_cubic(
    p0: tuple[float, float], p1: tuple[float, float],
    p2: tuple[float, float], p3: tuple[float, float],
    tol: float = _FLAT_TOL,
) -> list[tuple[float, float]]:
    """Flatten a cubic; returns the points after ``p0`` (ending at ``p3``).

    Every point of the curve lies within *tol* of the polyline.
    """
    d1x = p0[0] - 2 * p1[0] + p2[0]
    d1y = p0[1] - 2 * p1[1] + p2[1]
    d2x = p1[0] - 2 * p2[0] + p3[0]
    d2y = p1[1] - 2 * p2[1] + p3[1]
    m = max(d1x * d1x + d1y * d1y, d2x * d2x + d2y * d2y)
    if m != m or m == math.inf:
        steps = _MAX_STEPS
    else:
        steps = min(_MAX_STEPS, max(1, math.ceil(math.sqrt(0.75 * math.sqrt(m) / tol))))
    # polynomial form: P(t) = a t^3 + b t^2 + c t + p0
    cx_ = 3 * (p1[0] - p0[0])
    cy_ = 3 * (p1[1] - p0[1])
    bx = 3 * (p2[0] - p1[0]) - cx_
    by = 3 * (p2[1] - p1[1]) - cy_
    ax = p3[0] - p0[0] - cx_ - bx
    ay = p3[1] - p0[1] - cy_ - by
    out = []
    inv = 1.0 / steps
    for i in range(1, steps):
        t = i * inv
        out.append((((ax * t + bx) * t + cx_) * t + p0[0], ((ay * t + by) * t + cy_) * t + p0[1]))
    out.append(p3)
    return out


def flatten(path: Path, matrix: Matrix | None = None, tol: float = _FLAT_TOL) -> list[Subpath]:
    """Flatten *path*, optionally transforming it by *matrix* first.

    *tol* is the flattening tolerance in the output coordinate system.  A
    subpath is only reported if it has at least one drawing command (a lone
    ``M`` contributes nothing).
    """
    out: list[Subpath] = []
    pts: list[tuple[float, float]] | None = None
    drawn = False
    cur = (0.0, 0.0)

    def tf(x: float, y: float) -> tuple[float, float]:
        return (x, y) if matrix is None else apply(matrix, x, y)

    def finish(closed: bool) -> None:
        nonlocal pts, drawn
        if pts is not None and drawn:
            out.append(Subpath(pts, closed))
        pts = None
        drawn = False

    for seg in path:
        op = seg[0]
        if op == "M":
            finish(False)
            cur = tf(seg[1], seg[2])
            pts = [cur]
        elif op == "L":
            cur = tf(seg[1], seg[2])
            if pts is not None:
                pts.append(cur)
                drawn = True
        elif op == "C":
            p1 = tf(seg[1], seg[2])
            p2 = tf(seg[3], seg[4])
            p3 = tf(seg[5], seg[6])
            if pts is not None:
                pts.extend(flatten_cubic(cur, p1, p2, p3, tol))
                drawn = True
            cur = p3
        elif op == "Z":
            if pts is not None:
                drawn = True
                finish(True)
    finish(False)
    return out
