"""Scanline rasterisation, the RGBA canvas and PPM output.

:func:`rasterize` is an active-edge-table scan converter.  Each pixel row is
divided into :data:`SUBSAMPLES` sub-scanlines; the region is intersected with
each sub-scanline exactly, and the coverage of a pixel is the mean length of
the spans clipped to the pixel.  Work is proportional to the number of edges
and the area actually touched, never to the whole canvas.
"""

from __future__ import annotations

import math

__all__ = ["SUBSAMPLES", "rasterize", "Canvas", "encode_ppm"]

#: Sub-scanlines per pixel row.
SUBSAMPLES = 64

Point = tuple[float, float]
#: Coverage run: ``(row, first pixel x, [coverage in (0, 1] per pixel])``.
Run = tuple[int, int, list[float]]


def rasterize(polygons: list[list[Point]], evenodd: bool, width: int, height: int) -> list[Run]:
    """Compute the coverage of the region bounded by *polygons*.

    Each polygon is implicitly closed.  The region is chosen by the non-zero
    rule, or the even-odd rule if *evenodd* is true.  Returns one run per
    touched pixel row, in increasing row order.
    """
    nsub = SUBSAMPLES
    smax = height * nsub
    # edge: (first sub-scanline, x at sub-scanline 0 (extrapolated), dx per sub-scanline,
    #        end sub-scanline (exclusive), winding direction)
    edges: list[tuple[int, float, float, int, int]] = []
    isfinite = math.isfinite
    ceil = math.ceil
    for poly in polygons:
        n = len(poly)
        if n < 2:
            continue
        px, py = poly[-1]
        for x, y in poly:
            x0, y0, x1, y1 = px, py, x, y
            px, py = x, y
            if y0 == y1:
                continue
            if y0 < y1:
                direction = 1
            else:
                direction = -1
                x0, y0, x1, y1 = x1, y1, x0, y0
            if not (isfinite(x0) and isfinite(y0) and isfinite(x1) and isfinite(y1)):
                continue
            s_lo = ceil(y0 * nsub - 0.5)
            s_hi = ceil(y1 * nsub - 0.5)
            if s_lo < 0:
                s_lo = 0
            if s_hi > smax:
                s_hi = smax
            if s_lo >= s_hi:
                continue
            slope = (x1 - x0) / (y1 - y0)
            k = slope / nsub
            c = x0 + (0.5 / nsub - y0) * slope
            edges.append((s_lo, c, k, s_hi, direction))
    runs: list[Run] = []
    if not edges:
        return runs
    edges.sort()
    n_edges = len(edges)
    nxt = 0
    active: list[tuple[int, float, float, int, int]] = []
    cov = [0.0] * (width + 2)
    diff = [0] * (width + 2)
    row = -1
    xmin = width + 1
    xmax = -1
    fwidth = float(width)
    inv = 1.0 / nsub

    def flush() -> None:
        nonlocal xmin, xmax
        if xmax < 0:
            return
        hi = min(xmax, width - 1)
        out: list[float] = []
        run = 0
        for i in range(xmin, hi + 1):
            run += diff[i]
            v = (cov[i] + run) * inv
            out.append(v if v < 1.0 else 1.0)
        # reset touched entries (including the overflow slot at index xmax)
        for i in range(xmin, xmax + 2):
            cov[i] = 0.0
            diff[i] = 0
        runs.append((row, xmin, out))
        xmin = width + 1
        xmax = -1

    s = edges[0][0]
    while True:
        if not active:
            if nxt >= n_edges:
                break
            if edges[nxt][0] > s:
                s = edges[nxt][0]
        while nxt < n_edges and edges[nxt][0] <= s:
            active.append(edges[nxt])
            nxt += 1
        # drop finished edges and compute crossings
        crossings: list[tuple[float, int]] = []
        keep = []
        for e in active:
            if e[3] > s:
                keep.append(e)
                crossings.append((e[1] + s * e[2], e[4]))
        active = keep
        r = s // nsub
        if r != row:
            flush()
            row = r
        if len(crossings) >= 2:
            crossings.sort()
            wind = 0
            start = 0.0
            inside = False
            for x, d in crossings:
                wind += d
                now = (wind & 1) != 0 if evenodd else wind != 0
                if now and not inside:
                    start = x
                    inside = True
                elif inside and not now:
                    inside = False
                    # span [start, x]
                    x0 = start if start > 0.0 else 0.0
                    x1 = x if x < fwidth else fwidth
                    if x1 > x0:
                        i0 = int(x0)
                        i1 = int(x1)
                        if i0 == i1:
                            cov[i0] += x1 - x0
                        else:
                            cov[i0] += i0 + 1 - x0
                            cov[i1] += x1 - i1
                            diff[i0 + 1] += 1
                            diff[i1] -= 1
                        if i0 < xmin:
                            xmin = i0
                        if i1 > xmax:
                            xmax = i1
        s += 1
    flush()
    return runs


class Canvas:
    """A ``width x height`` canvas of premultiplied-style double RGBA.

    Channels are stored as the recurrences of SPEC §8.3 produce them
    (``dst.r = cr*alpha + dst.r*(1 - alpha)``) in flat row-major lists.
    """

    def __init__(self, width: int, height: int) -> None:
        self.width = width
        self.height = height
        size = width * height
        self.r = [0.0] * size
        self.g = [0.0] * size
        self.b = [0.0] * size
        self.a = [0.0] * size
        # dirty bounding box: rows [y0, y1], columns [x0, x1]
        self.y0 = height
        self.y1 = -1
        self.x0 = width
        self.x1 = -1

    def paint(self, runs: list[Run], color: tuple[float, float, float], opacity: float) -> None:
        """Source-over composite *color* with *opacity* through coverage *runs*."""
        cr, cg, cb = color
        R, G, B, A = self.r, self.g, self.b, self.a
        w = self.width
        for row, x0, covs in runs:
            base = row * w + x0
            if row < self.y0:
                self.y0 = row
            if row > self.y1:
                self.y1 = row
            if x0 < self.x0:
                self.x0 = x0
            last = x0 + len(covs) - 1
            if last > self.x1:
                self.x1 = last
            idx = base
            for cv in covs:
                if cv > 0.0:
                    alpha = opacity * cv
                    if alpha >= 1.0:
                        R[idx] = cr
                        G[idx] = cg
                        B[idx] = cb
                        A[idx] = 1.0
                    else:
                        ia = 1.0 - alpha
                        R[idx] = cr * alpha + R[idx] * ia
                        G[idx] = cg * alpha + G[idx] * ia
                        B[idx] = cb * alpha + B[idx] * ia
                        A[idx] = alpha + A[idx] * ia
                idx += 1

    def composite(self, src: "Canvas", opacity: float) -> None:
        """Composite the layer *src* onto this canvas with group *opacity*."""
        if src.y1 < 0:
            return
        w = self.width
        R, G, B, A = self.r, self.g, self.b, self.a
        sR, sG, sB, sA = src.r, src.g, src.b, src.a
        for row in range(src.y0, src.y1 + 1):
            for idx in range(row * w + src.x0, row * w + src.x1 + 1):
                sa = sA[idx]
                if sa == 0.0:
                    continue
                ia = 1.0 - sa * opacity
                R[idx] = sR[idx] * opacity + R[idx] * ia
                G[idx] = sG[idx] * opacity + G[idx] * ia
                B[idx] = sB[idx] * opacity + B[idx] * ia
                A[idx] = sa * opacity + A[idx] * ia
        self.y0 = min(self.y0, src.y0)
        self.y1 = max(self.y1, src.y1)
        self.x0 = min(self.x0, src.x0)
        self.x1 = max(self.x1, src.x1)

    def to_rgb_bytes(self) -> bytes:
        """Composite over opaque white and return packed 8-bit RGB."""
        out = bytearray(self.width * self.height * 3)
        pos = 0
        for r, g, b, a in zip(self.r, self.g, self.b, self.a):
            ia = 1.0 - a
            for v in (r + ia, g + ia, b + ia):
                if v <= 0.0:
                    q = 0
                elif v >= 1.0:
                    q = 255
                else:
                    q = int(v * 255.0 + 0.5)
                out[pos] = q
                pos += 1
        return bytes(out)


def encode_ppm(width: int, height: int, rgb: bytes) -> bytes:
    """Encode packed RGB bytes as a binary PPM (P6) file."""
    return b"P6\n%d %d\n255\n" % (width, height) + rgb
