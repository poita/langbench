/// Vector paths: construction (including elliptical arcs) and flattening to
/// polylines within a tolerance.
module svgraster.path;

import std.math : sqrt, abs, ceil, atan2, cos, sin, tan, PI, isFinite;
import svgraster.geom;

/// The kind of a path segment.
enum SegKind : ubyte
{
    move,
    line,
    cubic,
    close,
}

/// One path segment. `move` and `line` use `p3` as the end point; `cubic` uses
/// `p1`, `p2` as control points and `p3` as the end point.
struct Segment
{
    SegKind kind;
    Point p1, p2, p3;
}

/// A path built from `M`, `L`, `C` and `Z` segments.
struct Path
{
    /// The segments in order.
    Segment[] segments;

    /// Current point (valid once a segment has been added).
    Point current;
    /// Start of the current subpath.
    Point start;

    /// Begin a subpath at `p`.
    void moveTo(Point p)
    {
        segments ~= Segment(SegKind.move, Point.init, Point.init, p);
        current = start = p;
    }

    /// Straight line to `p`.
    void lineTo(Point p)
    {
        segments ~= Segment(SegKind.line, Point.init, Point.init, p);
        current = p;
    }

    /// Cubic Bézier to `p` with control points `c1` and `c2`.
    void cubicTo(Point c1, Point c2, Point p)
    {
        segments ~= Segment(SegKind.cubic, c1, c2, p);
        current = p;
    }

    /// Close the current subpath; the current point returns to its start.
    void close()
    {
        segments ~= Segment(SegKind.close);
        current = start;
    }

    /// Elliptical arc from the current point to `to`, with the SVG 1.1
    /// endpoint parameterisation (implementation notes F.6.5, F.6.6),
    /// approximated by cubic segments of at most a quarter turn each.
    void arcTo(double rx, double ry, double rotationDeg, bool largeArc, bool sweep, Point to)
    {
        immutable from = current;
        if (from.x == to.x && from.y == to.y)
            return;
        rx = abs(rx);
        ry = abs(ry);
        if (rx == 0 || ry == 0)
        {
            lineTo(to);
            return;
        }
        immutable phi = rotationDeg * PI / 180;
        immutable cphi = cos(phi), sphi = sin(phi);

        // F.6.5.1
        immutable dx2 = (from.x - to.x) / 2, dy2 = (from.y - to.y) / 2;
        immutable x1p = cphi * dx2 + sphi * dy2;
        immutable y1p = -sphi * dx2 + cphi * dy2;

        // F.6.6.2
        immutable lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
        if (lambda > 1)
        {
            immutable sl = sqrt(lambda);
            rx *= sl;
            ry *= sl;
        }

        // F.6.5.2
        immutable rx2 = rx * rx, ry2 = ry * ry;
        immutable num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
        immutable den = rx2 * y1p * y1p + ry2 * x1p * x1p;
        double coef = den == 0 ? 0 : sqrt(num / den < 0 ? 0 : num / den);
        if (largeArc == sweep)
            coef = -coef;
        immutable cxp = coef * (rx * y1p / ry);
        immutable cyp = coef * -(ry * x1p / rx);

        // F.6.5.3
        immutable cx = cphi * cxp - sphi * cyp + (from.x + to.x) / 2;
        immutable cy = sphi * cxp + cphi * cyp + (from.y + to.y) / 2;

        // F.6.5.5, F.6.5.6
        immutable ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry;
        immutable vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry;
        immutable theta1 = atan2(uy, ux);
        double dtheta = atan2(ux * vy - uy * vx, ux * vx + uy * vy);
        if (sweep && dtheta < 0)
            dtheta += 2 * PI;
        else if (!sweep && dtheta > 0)
            dtheta -= 2 * PI;

        int n = cast(int) ceil(abs(dtheta) / (PI / 4));
        if (n < 1)
            n = 1;
        immutable delta = dtheta / n;
        immutable k = 4.0 / 3.0 * tan(delta / 4);

        Point ellipse(double t)
        {
            immutable ex = rx * cos(t), ey = ry * sin(t);
            return Point(cx + cphi * ex - sphi * ey, cy + sphi * ex + cphi * ey);
        }
        Point tangent(double t)
        {
            immutable ex = -rx * sin(t), ey = ry * cos(t);
            return Point(cphi * ex - sphi * ey, sphi * ex + cphi * ey);
        }

        Point p0 = from;
        foreach (seg; 0 .. n)
        {
            immutable t0 = theta1 + seg * delta;
            immutable t1 = t0 + delta;
            immutable e0 = ellipse(t0);
            immutable e1 = ellipse(t1);
            immutable d0 = tangent(t0);
            immutable d1 = tangent(t1);
            immutable c1 = Point(e0.x + k * d0.x, e0.y + k * d0.y);
            immutable c2 = Point(e1.x - k * d1.x, e1.y - k * d1.y);
            immutable p3 = seg == n - 1 ? to : e1;
            cubicTo(c1, c2, p3);
            p0 = p3;
        }
    }

    /// A copy of this path with every point transformed by `m`.
    Path transformed(const Matrix m) const
    {
        Path r;
        r.segments.length = segments.length;
        foreach (i, s; segments)
        {
            r.segments[i] = Segment(s.kind, m.apply(s.p1), m.apply(s.p2), m.apply(s.p3));
        }
        return r;
    }
}

/// A flattened subpath.
struct Polyline
{
    /// Vertices in order. A subpath with a single point is legal.
    Point[] points;
    /// `true` if the subpath ended with `Z`.
    bool closed;
}

/// Flatten `path` to polylines so that every point of each curve lies within
/// `tolerance` (in the units of `path`) of the polyline.
///
/// A subpath starts at each `move`. A lone `move` with nothing after it is not
/// a subpath and is dropped. After a `close`, a drawing segment starts a new
/// subpath at the start point of the closed one.
Polyline[] flatten(const Path path, double tolerance)
{
    Polyline[] result;
    Polyline cur;
    bool active = false, haveStart = false;
    Point start, pos;

    void flush()
    {
        if (active && (cur.points.length > 1 || cur.closed))
            result ~= cur;
        cur = Polyline.init;
        active = false;
    }

    void ensureOpen()
    {
        if (!active || cur.closed)
        {
            flush();
            cur.points = [start];
            active = true;
            pos = start;
        }
    }

    foreach (ref s; path.segments)
    {
        final switch (s.kind)
        {
        case SegKind.move:
            flush();
            cur.points = [s.p3];
            active = true;
            start = pos = s.p3;
            haveStart = true;
            break;
        case SegKind.line:
            if (!haveStart)
                break;
            ensureOpen();
            cur.points ~= s.p3;
            pos = s.p3;
            break;
        case SegKind.cubic:
            if (!haveStart)
                break;
            ensureOpen();
            flattenCubic(cur.points, pos, s.p1, s.p2, s.p3, tolerance);
            pos = s.p3;
            break;
        case SegKind.close:
            if (active && !cur.closed)
            {
                cur.closed = true;
                pos = start;
            }
            break;
        }
    }
    flush();
    return result;
}

/// Number of equal parameter steps used to flatten a cubic.
int cubicSteps(Point p0, Point p1, Point p2, Point p3, double tolerance)
{
    immutable a = Point(p0.x - 2 * p1.x + p2.x, p0.y - 2 * p1.y + p2.y);
    immutable b = Point(p1.x - 2 * p2.x + p3.x, p1.y - 2 * p2.y + p3.y);
    immutable m = a.x * a.x + a.y * a.y > b.x * b.x + b.y * b.y
        ? a.x * a.x + a.y * a.y : b.x * b.x + b.y * b.y;
    if (!isFinite(m))
        return 1;
    immutable nf = ceil(sqrt(0.75 * sqrt(m) / tolerance));
    if (!(nf >= 1))
        return 1;
    return nf > 1000 ? 1000 : cast(int) nf;
}

/// Append the points of a flattened cubic (excluding the start point).
void flattenCubic(ref Point[] out_, Point p0, Point p1, Point p2, Point p3, double tolerance)
{
    immutable n = cubicSteps(p0, p1, p2, p3, tolerance);
    foreach (i; 1 .. n)
    {
        immutable t = cast(double) i / n;
        immutable u = 1 - t;
        immutable w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t;
        out_ ~= Point(w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x,
                w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y);
    }
    out_ ~= p3;
}

unittest
{
    import std.math : isClose;

    Path p;
    p.moveTo(Point(0, 0));
    p.lineTo(Point(10, 0));
    p.lineTo(Point(10, 10));
    p.close();
    auto polys = flatten(p, 0.01);
    assert(polys.length == 1 && polys[0].closed && polys[0].points.length == 3);

    // A lone move is not a subpath; a closed lone move is.
    Path q;
    q.moveTo(Point(1, 1));
    q.moveTo(Point(2, 2));
    q.close();
    q.lineTo(Point(5, 5));
    polys = flatten(q, 0.01);
    assert(polys.length == 2 && polys[0].closed && polys[0].points.length == 1);
    assert(polys[1].points == [Point(2, 2), Point(5, 5)]);
}

unittest
{
    import std.math : isClose;

    // A half circle of radius 5: all flattened points are close to the circle.
    Path p;
    p.moveTo(Point(0, 0));
    p.arcTo(5, 5, 0, false, true, Point(10, 0));
    auto polys = flatten(p, 0.01);
    assert(polys.length == 1);
    foreach (pt; polys[0].points)
    {
        immutable r = Point(pt.x - 5, pt.y).length;
        assert(abs(r - 5) < 0.011);
    }
    // Radii that are too small are scaled up; identical endpoints are dropped.
    Path q;
    q.moveTo(Point(0, 0));
    q.arcTo(1, 1, 0, false, false, Point(10, 0));
    assert(abs(q.current.x - 10) < 1e-12);
    Path z;
    z.moveTo(Point(3, 3));
    z.arcTo(1, 1, 0, false, false, Point(3, 3));
    assert(z.segments.length == 1);
}
