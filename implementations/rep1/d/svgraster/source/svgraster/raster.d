/// The RGBA canvas and the anti-aliasing scanline rasteriser (SPEC §8.3).
///
/// Coverage comes from an active-edge-table sweep over 64 equally spaced
/// sub-scanlines per pixel row. Exact span lengths are accumulated into a pair
/// of per-row arrays (`cover` for partial pixels, `delta` for runs of fully
/// covered pixels) and each finished row is blended straight into the canvas.
module svgraster.raster;

import std.algorithm.sorting : sort;
import std.math : ceil, floor, isFinite;
import svgraster.buf;
import svgraster.geom;

/// Winding rules for filling.
enum FillRule : ubyte { nonzero, evenodd }

/// Number of sub-scanlines per pixel row.
enum int subScanlines = 64;

/// An RGBA canvas of `double` channels, straight alpha, interleaved. It also
/// remembers which rows have been painted, so layers can be composited and
/// cleared cheaply.
final class Canvas
{
    /// Width in pixels.
    int width;
    /// Height in pixels.
    int height;
    /// `width * height * 4` channels, rows top to bottom.
    double[] px;
    /// Inclusive range of rows touched since the last `clear` (empty when
    /// `rowLo > rowHi`).
    int rowLo, rowHi;

    this(int width, int height) pure nothrow @safe
    {
        this.width = width;
        this.height = height;
        px = new double[](cast(size_t) width * height * 4);
        px[] = 0.0;
        rowLo = int.max;
        rowHi = -1;
    }

    /// Record that row `y` was painted.
    void touch(int y) pure nothrow @nogc @safe
    {
        if (y < rowLo)
            rowLo = y;
        if (y > rowHi)
            rowHi = y;
    }

    /// Reset the touched rows to transparent.
    void clear() pure nothrow @nogc @safe
    {
        if (rowHi >= rowLo)
            px[cast(size_t) rowLo * width * 4 .. (cast(size_t) rowHi + 1) * width * 4] = 0.0;
        rowLo = int.max;
        rowHi = -1;
    }

    /// Composite `layer` (same size) over this canvas with group opacity `o`
    /// (SPEC §8.4), visiting only the layer's touched rows.
    void compositeLayer(const Canvas layer, double o) pure nothrow @nogc @trusted
    {
        if (layer.rowHi < layer.rowLo)
            return;
        foreach (y; layer.rowLo .. layer.rowHi + 1)
        {
            size_t i = cast(size_t) y * width * 4;
            foreach (x; 0 .. width)
            {
                immutable sa = layer.px[i + 3];
                if (sa > 0)
                {
                    immutable k = 1 - sa * o;
                    px[i] = layer.px[i] * o + px[i] * k;
                    px[i + 1] = layer.px[i + 1] * o + px[i + 1] * k;
                    px[i + 2] = layer.px[i + 2] * o + px[i + 2] * k;
                    px[i + 3] = sa * o + px[i + 3] * k;
                }
                i += 4;
            }
            touch(y);
        }
    }

    /// Composite over opaque white and convert to 8-bit RGB (SPEC §8.5).
    ubyte[] toRgb8() const pure nothrow @safe
    {
        auto o = new ubyte[](cast(size_t) width * height * 3);
        size_t j = 0;
        for (size_t i = 0; i < px.length; i += 4)
        {
            immutable inv = 1 - px[i + 3];
            foreach (c; 0 .. 3)
            {
                double v = px[i + c] + inv;
                v = v < 0 ? 0 : (v > 1 ? 1 : v);
                o[j++] = cast(ubyte) floor(v * 255 + 0.5);
            }
        }
        return o;
    }
}

private struct Edge
{
    double xt, yt, dxdy;
    int k0, k1;
    int dir;
}

private struct Active
{
    double x, xt, yt, dxdy;
    int k1;
    int dir;
}

/// Scan converter. Add polygons with `addPolygon`, then call `fill` to
/// paint their union (by the given rule) onto a canvas of the same size.
/// Scratch buffers are reused between calls.
final class Rasterizer
{
    private int w, h;
    private Buf!Edge edges;
    private Buf!Active active;
    private double[] cover, delta;
    private int xlo, xhi;

    this(int width, int height) pure nothrow @safe
    {
        w = width;
        h = height;
        cover = new double[](width + 2);
        delta = new double[](width + 2);
        cover[] = 0.0;
        delta[] = 0.0;
    }

    /// Discard all polygons.
    void begin() pure nothrow @safe
    {
        edges.clear();
    }

    /// Add a closed polygon (the last point connects back to the first).
    void addPolygon(const(Vec2)[] pts) pure nothrow @safe
    {
        immutable n = pts.length;
        if (n < 3)
            return;
        foreach (i; 0 .. n)
        {
            immutable a = pts[i], b = pts[i + 1 == n ? 0 : i + 1];
            addEdge(a.x, a.y, b.x, b.y);
        }
    }

    private void addEdge(double x0, double y0, double x1, double y1) pure nothrow @trusted
    {
        if (y0 == y1 || !isFinite(x0) || !isFinite(y0) || !isFinite(x1) || !isFinite(y1))
            return;
        int dir = 1;
        if (y1 < y0)
        {
            immutable tx = x0, ty = y0;
            x0 = x1;
            y0 = y1;
            x1 = tx;
            y1 = ty;
            dir = -1;
        }
        double k0 = ceil(subScanlines * y0 - 0.5);
        double k1 = ceil(subScanlines * y1 - 0.5) - 1;
        if (k0 < 0)
            k0 = 0;
        immutable kmax = cast(double) h * subScanlines - 1;
        if (k1 > kmax)
            k1 = kmax;
        if (k0 > k1)
            return;
        edges.push(Edge(x0, y0, (x1 - x0) / (y1 - y0), cast(int) k0, cast(int) k1, dir));
    }

    /// Paint the polygons added since `begin` onto `cv` with colour
    /// `(r, g, b)` and paint opacity `opacity`.
    void fill(Canvas cv, FillRule rule, double r, double g, double b, double opacity) @trusted
    {
        assert(cv.width == w && cv.height == h);
        immutable ne = edges.length;
        if (ne == 0)
            return;
        edges.slice.sort!((p, q) => p.k0 < q.k0);
        auto es = edges.slice;
        active.clear();
        xlo = int.max;
        xhi = -1;
        size_t next = 0;
        int k = es[0].k0;
        int curRow = -1;
        size_t na = 0;
        while (next < ne || na > 0)
        {
            if (na == 0 && es[next].k0 > k)
                k = es[next].k0;
            immutable yk = (k + 0.5) / subScanlines;
            while (next < ne && es[next].k0 <= k)
            {
                immutable e = es[next++];
                if (na < active.length)
                    active[na] = Active(0, e.xt, e.yt, e.dxdy, e.k1, e.dir);
                else
                    active.push(Active(0, e.xt, e.yt, e.dxdy, e.k1, e.dir));
                ++na;
            }
            auto act = active.slice;
            size_t wr = 0;
            foreach (i; 0 .. na)
            {
                auto a = act[i];
                if (a.k1 < k)
                    continue;
                a.x = a.xt + (yk - a.yt) * a.dxdy;
                act[wr++] = a;
            }
            na = wr;
            if (na == 0)
                continue;
            // Insertion sort: the order barely changes between sub-scanlines.
            foreach (i; 1 .. na)
            {
                auto a = act[i];
                size_t j = i;
                while (j > 0 && act[j - 1].x > a.x)
                {
                    act[j] = act[j - 1];
                    --j;
                }
                act[j] = a;
            }
            immutable row = k / subScanlines;
            if (row != curRow)
            {
                if (curRow >= 0)
                    flushRow(cv, curRow, r, g, b, opacity);
                curRow = row;
            }
            if (rule == FillRule.nonzero)
            {
                int wind = 0;
                double sx = 0;
                foreach (i; 0 .. na)
                {
                    immutable prev = wind;
                    wind += act[i].dir;
                    if (prev == 0)
                        sx = act[i].x;
                    else if (wind == 0)
                        addSpan(sx, act[i].x);
                }
            }
            else
            {
                double sx = 0;
                foreach (i; 0 .. na)
                {
                    if ((i & 1) == 0)
                        sx = act[i].x;
                    else
                        addSpan(sx, act[i].x);
                }
            }
            ++k;
        }
        if (curRow >= 0)
            flushRow(cv, curRow, r, g, b, opacity);
    }

    private void addSpan(double xa, double xb) pure nothrow @nogc @trusted
    {
        if (xa < 0)
            xa = 0;
        if (xb > w)
            xb = w;
        if (!(xb > xa))
            return;
        immutable ia = cast(int) xa, ib = cast(int) xb;
        if (ia == ib)
            cover[ia] += xb - xa;
        else
        {
            cover[ia] += (ia + 1) - xa;
            cover[ib] += xb - ib;
            delta[ia + 1] += 1;
            delta[ib] -= 1;
        }
        if (ia < xlo)
            xlo = ia;
        if (ib > xhi)
            xhi = ib;
    }

    private void flushRow(Canvas cv, int row, double r, double g, double b, double opacity) pure nothrow @nogc @trusted
    {
        if (xhi < xlo)
            return;
        immutable last = xhi < w - 1 ? xhi : w - 1;
        double* p = &cv.px[(cast(size_t) row * w + xlo) * 4];
        double run = 0;
        enum inv = 1.0 / subScanlines;
        foreach (i; xlo .. last + 1)
        {
            run += delta[i];
            double cov = (cover[i] + run) * inv;
            if (cov > 1)
                cov = 1;
            immutable a = opacity * cov;
            if (a > 0)
            {
                immutable k = 1 - a;
                p[0] = r * a + p[0] * k;
                p[1] = g * a + p[1] * k;
                p[2] = b * a + p[2] * k;
                p[3] = a + p[3] * k;
            }
            p += 4;
        }
        cover[xlo .. xhi + 2] = 0.0;
        delta[xlo .. xhi + 2] = 0.0;
        cv.touch(row);
        xlo = int.max;
        xhi = -1;
    }
}
