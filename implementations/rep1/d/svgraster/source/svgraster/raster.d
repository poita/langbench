/// The RGBA canvas, the anti-aliased scanline polygon filler and the PPM
/// writer.
///
/// Coverage is computed with 64 equally spaced sub-scanlines per pixel row:
/// the polygon edges are intersected with each sub-scanline exactly, the
/// resulting x spans are clipped to the pixels they overlap and their lengths
/// are averaged. Only sub-scanlines that have active edges are visited, and
/// the work per paint operation is bounded by the area it touches.
module svgraster.raster;

import std.algorithm : sort, min, max;
import std.math : ceil, floor, isFinite;
import std.array : appender;
import svgraster.geom;

/// How the interior of a polygon set is decided.
enum FillRule : ubyte
{
    nonzero,
    evenodd,
}

/// A paint source: colour channels in `[0, 1]` and an opacity.
struct Paint
{
    double r, g, b;
    double opacity = 1;
}

/// A canvas of premultiplied-alpha RGBA pixels in double precision. All
/// channels start transparent.
final class Canvas
{
    /// Width in pixels.
    immutable int width;
    /// Height in pixels.
    immutable int height;
    /// `width * height * 4` doubles: r, g, b (already multiplied by a), a.
    double[] pixels;

    this(int width, int height)
    {
        assert(width > 0 && height > 0);
        this.width = width;
        this.height = height;
        pixels = new double[cast(size_t) width * height * 4];
        pixels[] = 0.0;
    }

    /// Composite `src` onto this canvas with an extra opacity factor `o`
    /// (SPEC.md §8.4).
    void compositeLayer(const Canvas src, double o)
    {
        assert(src.width == width && src.height == height);
        for (size_t i = 0; i < pixels.length; i += 4)
        {
            immutable sa = src.pixels[i + 3] * o;
            if (sa == 0)
                continue;
            immutable k = 1 - sa;
            pixels[i] = src.pixels[i] * o + pixels[i] * k;
            pixels[i + 1] = src.pixels[i + 1] * o + pixels[i + 1] * k;
            pixels[i + 2] = src.pixels[i + 2] * o + pixels[i + 2] * k;
            pixels[i + 3] = sa + pixels[i + 3] * k;
        }
    }

    /// Source-over composite of colour `p` with the given coverage at pixel
    /// `(x, y)`.
    void blend(int x, int y, const Paint p, double coverage)
    {
        immutable alpha = p.opacity * coverage;
        immutable k = 1 - alpha;
        immutable i = (cast(size_t) y * width + x) * 4;
        pixels[i] = p.r * alpha + pixels[i] * k;
        pixels[i + 1] = p.g * alpha + pixels[i + 1] * k;
        pixels[i + 2] = p.b * alpha + pixels[i + 2] * k;
        pixels[i + 3] = alpha + pixels[i + 3] * k;
    }

    /// Composite over opaque white and encode as a binary PPM (P6) file.
    ubyte[] toPpm() const
    {
        import std.format : format;

        immutable header = format("P6\n%d %d\n255\n", width, height);
        auto buf = new ubyte[header.length + cast(size_t) width * height * 3];
        buf[0 .. header.length] = cast(const(ubyte)[]) header;
        size_t o = header.length;
        for (size_t i = 0; i < pixels.length; i += 4)
        {
            immutable inv = 1 - pixels[i + 3];
            foreach (c; 0 .. 3)
            {
                double v = pixels[i + c] + inv;
                v = v < 0 ? 0 : (v > 1 ? 1 : v);
                buf[o++] = cast(ubyte) floor(v * 255 + 0.5);
            }
        }
        return buf;
    }
}

private enum subScanlines = 64;

private struct Edge
{
    double x0, y0; // upper end (y0 < y1)
    double slope; // dx/dy
    long first; // first sub-scanline that samples the edge
    long last; // one past the last
    int dir; // +1 downwards, -1 upwards
}

/// Reusable scratch space for filling polygons onto canvases of one width.
struct Rasterizer
{
    private double[] cover;
    private double[] runs;

    /// Fill the polygons with `rule` onto `canvas` using `paint`. Every
    /// polygon is implicitly closed.
    void fill(Canvas canvas, const(Point[])[] polygons, FillRule rule, const Paint paint)
    {
        immutable W = canvas.width;
        immutable H = canvas.height;
        immutable maxSub = cast(long) H * subScanlines;

        Edge[] edges;
        foreach (poly; polygons)
        {
            immutable n = poly.length;
            if (n < 2)
                continue;
            foreach (i; 0 .. n)
            {
                immutable a = poly[i], b = poly[(i + 1) % n];
                addEdge(edges, a, b, maxSub);
            }
        }
        if (edges.length == 0)
            return;
        sort!((p, q) => p.first < q.first)(edges);

        if (cover.length < W + 2)
        {
            cover = new double[W + 2];
            runs = new double[W + 2];
            cover[] = 0;
            runs[] = 0;
        }

        size_t[] active;
        size_t next = 0;
        long s = edges[0].first;
        long curRow = -1;
        int minX = int.max, maxX = -1;
        double[] xs;

        void flushRow()
        {
            if (curRow < 0 || maxX < 0)
                return;
            double run = 0;
            immutable row = cast(int) curRow;
            foreach (x; minX .. maxX + 1)
            {
                run += runs[x];
                double c = (cover[x] + run) * (1.0 / subScanlines);
                cover[x] = 0;
                runs[x] = 0;
                if (x < W && c > 1e-9)
                    canvas.blend(x, row, paint, c > 1 ? 1 : c);
            }
            runs[maxX + 1] = 0;
            minX = int.max;
            maxX = -1;
        }

        while (s < maxSub)
        {
            if (active.length == 0)
            {
                if (next >= edges.length)
                    break;
                if (edges[next].first > s)
                    s = edges[next].first;
                if (s >= maxSub)
                    break;
            }
            while (next < edges.length && edges[next].first <= s)
                active ~= next++;

            immutable row = s / subScanlines;
            if (row != curRow)
            {
                flushRow();
                curRow = row;
            }
            immutable y = (s + 0.5) / subScanlines;

            // Drop finished edges, compute crossings.
            size_t w = 0;
            foreach (idx; active)
            {
                if (edges[idx].last > s)
                    active[w++] = idx;
            }
            active.length = w;
            if (xs.length < w)
                xs.length = w * 2;
            foreach (i; 0 .. w)
            {
                const e = &edges[active[i]];
                xs[i] = e.x0 + (y - e.y0) * e.slope;
            }
            // Keep `active` ordered by crossing x. Insertion sort: the order
            // changes little from one sub-scanline to the next.
            foreach (i; 1 .. w)
            {
                immutable key = xs[i];
                immutable ki = active[i];
                size_t j = i;
                while (j > 0 && xs[j - 1] > key)
                {
                    xs[j] = xs[j - 1];
                    active[j] = active[j - 1];
                    --j;
                }
                xs[j] = key;
                active[j] = ki;
            }

            int winding = 0;
            double spanStart = 0;
            foreach (i; 0 .. w)
            {
                immutable before = winding;
                if (rule == FillRule.nonzero)
                    winding += edges[active[i]].dir;
                else
                    winding = winding == 0 ? 1 : 0;
                if (before == 0 && winding != 0)
                    spanStart = xs[i];
                else if (before != 0 && winding == 0)
                    addSpan(W, spanStart, xs[i], minX, maxX);
            }
            ++s;
        }
        flushRow();
    }

    private void addSpan(int W, double x0, double x1, ref int minX, ref int maxX)
    {
        if (x0 < 0)
            x0 = 0;
        if (x1 > W)
            x1 = W;
        if (!(x1 > x0))
            return;
        immutable i0 = cast(int) floor(x0);
        immutable i1 = cast(int) floor(x1);
        if (i0 < minX)
            minX = i0;
        if (i1 > maxX)
            maxX = i1;
        if (i0 == i1)
        {
            cover[i0] += x1 - x0;
        }
        else
        {
            cover[i0] += i0 + 1 - x0;
            cover[i1] += x1 - i1;
            runs[i0 + 1] += 1;
            runs[i1] -= 1;
        }
    }
}

private void addEdge(ref Edge[] edges, Point a, Point b, long maxSub)
{
    if (!isFinite(a.x) || !isFinite(a.y) || !isFinite(b.x) || !isFinite(b.y))
        return;
    if (a.y == b.y)
        return;
    int dir = 1;
    if (a.y > b.y)
    {
        immutable t = a;
        a = b;
        b = t;
        dir = -1;
    }
    // Sub-scanline s samples y = (s + 0.5) / 64; the edge covers it when
    // a.y <= y < b.y.
    long idx(double y)
    {
        immutable v = ceil(y * subScanlines - 0.5);
        if (v < 0)
            return 0;
        if (v > maxSub)
            return maxSub;
        return cast(long) v;
    }

    immutable first = idx(a.y);
    immutable last = idx(b.y);
    if (first >= last)
        return;
    edges ~= Edge(a.x, a.y, (b.x - a.x) / (b.y - a.y), first, last, dir);
}

unittest
{
    // Fractional-coverage rectangle from SPEC.md §10.1.
    auto c = new Canvas(8, 4);
    Rasterizer r;
    immutable poly = [Point(1, 1), Point(4.5, 1), Point(4.5, 3), Point(1, 3)];
    r.fill(c, [poly], FillRule.nonzero, Paint(0, 0, 1));
    const ppm = c.toPpm();
    immutable hdr = "P6\n8 4\n255\n".length;
    auto px(int x, int y) { return ppm[hdr + (y * 8 + x) * 3 .. hdr + (y * 8 + x) * 3 + 3]; }
    assert(px(0, 1) == [255, 255, 255]);
    assert(px(1, 1) == [0, 0, 255]);
    assert(px(3, 2) == [0, 0, 255]);
    assert(px(4, 1) == [128, 128, 255]);
    assert(px(5, 1) == [255, 255, 255]);
    assert(px(2, 0) == [255, 255, 255] && px(2, 3) == [255, 255, 255]);
}

unittest
{
    import std.math : isClose;

    // Winding rules: a doubled square is filled by nonzero, empty with evenodd.
    immutable sq = [Point(0, 0), Point(4, 0), Point(4, 4), Point(0, 4)];
    auto a = new Canvas(4, 4);
    Rasterizer r;
    r.fill(a, [sq, sq], FillRule.nonzero, Paint(0, 0, 0));
    assert(isClose(a.pixels[3], 1.0));
    auto b = new Canvas(4, 4);
    r.fill(b, [sq, sq], FillRule.evenodd, Paint(0, 0, 0));
    assert(b.pixels[3] == 0);
    // Opposite orientation cancels under nonzero too.
    immutable rev = [Point(0, 4), Point(4, 4), Point(4, 0), Point(0, 0)];
    auto d = new Canvas(4, 4);
    r.fill(d, [sq, rev], FillRule.nonzero, Paint(0, 0, 0));
    assert(d.pixels[3] == 0);
}

unittest
{
    import std.math : isClose;

    // A triangle's coverage sums to its area; geometry off canvas is clipped.
    auto c = new Canvas(10, 10);
    Rasterizer r;
    r.fill(c, [[Point(-5, -5), Point(15, -5), Point(-5, 15)]], FillRule.nonzero, Paint(1, 1, 1));
    double total = 0;
    for (size_t i = 3; i < c.pixels.length; i += 4)
        total += c.pixels[i];
    assert(isClose(total, 50, 1e-3));
}

unittest
{
    // Group compositing: 50% of an opaque black layer over transparent.
    auto base = new Canvas(1, 1);
    auto layer = new Canvas(1, 1);
    Rasterizer r;
    r.fill(layer, [[Point(0, 0), Point(1, 0), Point(1, 1), Point(0, 1)]],
            FillRule.nonzero, Paint(1, 0, 0));
    base.compositeLayer(layer, 0.5);
    assert(base.pixels[0] == 0.5 && base.pixels[3] == 0.5);
}
