/// Stroke outlining: turns flattened subpaths into a set of polygons whose
/// nonzero-union is the stroked region (SPEC.md §8.2).
module svgraster.stroke;

import std.math : sqrt, acos, atan2, cos, sin, PI, ceil, abs;
import svgraster.geom;
import svgraster.path;

/// Shape of the end of an open subpath.
enum LineCap : ubyte
{
    butt,
    round,
    square,
}

/// Shape of the corner between two segments.
enum LineJoin : ubyte
{
    miter,
    round,
    bevel,
}

/// Stroke parameters, in user units.
struct StrokeStyle
{
    double width = 1;
    LineCap cap = LineCap.butt;
    LineJoin join = LineJoin.miter;
    double miterLimit = 4;
}

/// A convex-ish piece of the outline.
alias Polygon = Point[];

/// Build the stroke outline of `subpaths` (already flattened, in user space).
///
/// Every returned polygon is oriented to have positive signed area, so filling
/// them all with the nonzero rule gives their union.
///
/// Params:
///   subpaths = flattened subpaths in user space.
///   style = stroke width, caps, joins and miter limit.
///   arcTolerance = maximum distance between a round cap/join and its
///                  polyline approximation, in user units.
Polygon[] strokeOutline(const Polyline[] subpaths, const StrokeStyle style, double arcTolerance)
{
    Polygon[] pieces;
    immutable r = style.width / 2;
    immutable miterLimit = style.miterLimit < 1 ? 1.0 : style.miterLimit;

    void emit(Polygon poly)
    {
        double area2 = 0;
        foreach (i; 0 .. poly.length)
        {
            immutable a = poly[i], b = poly[(i + 1) % poly.length];
            area2 += a.x * b.y - b.x * a.y;
        }
        if (area2 < 0)
        {
            foreach (i; 0 .. poly.length / 2)
            {
                immutable t = poly[i];
                poly[i] = poly[$ - 1 - i];
                poly[$ - 1 - i] = t;
            }
        }
        pieces ~= poly;
    }

    // Polyline approximating the arc of radius r about c from angle a0
    // sweeping by `sweep` radians (endpoints included).
    Point[] arc(Point c, double a0, double sweep)
    {
        double step = arcStep(r, arcTolerance);
        int n = cast(int) ceil(abs(sweep) / step);
        if (n < 1)
            n = 1;
        if (n > 4096)
            n = 4096;
        Point[] pts;
        pts.reserve(n + 1);
        foreach (i; 0 .. n + 1)
        {
            immutable t = a0 + sweep * i / n;
            pts ~= Point(c.x + r * cos(t), c.y + r * sin(t));
        }
        return pts;
    }

    foreach (ref sp; subpaths)
    {
        // Drop repeated points.
        Point[] p;
        foreach (pt; sp.points)
            if (p.length == 0 || pt != p[$ - 1])
                p ~= pt;
        if (sp.closed && p.length > 1 && p[$ - 1] == p[0])
            p = p[0 .. $ - 1];
        immutable n = p.length;
        if (n == 0)
            continue;

        if (n == 1)
        {
            final switch (style.cap)
            {
            case LineCap.butt:
                break;
            case LineCap.round:
                emit(arc(p[0], 0, 2 * PI)[0 .. $ - 1]);
                break;
            case LineCap.square:
                emit([Point(p[0].x - r, p[0].y - r), Point(p[0].x + r, p[0].y - r),
                        Point(p[0].x + r, p[0].y + r), Point(p[0].x - r, p[0].y + r)]);
                break;
            }
            continue;
        }

        immutable segCount = sp.closed ? n : n - 1;
        Point[] dir = new Point[segCount];
        foreach (i; 0 .. segCount)
        {
            immutable a = p[i], b = p[(i + 1) % n];
            immutable d = b - a;
            immutable len = d.length;
            dir[i] = Point(d.x / len, d.y / len);
            immutable nrm = Point(-dir[i].y * r, dir[i].x * r);
            emit([a + nrm, b + nrm, b - nrm, a - nrm]);
        }

        // Joins.
        immutable firstJoint = sp.closed ? 0 : 1;
        immutable lastJoint = sp.closed ? n - 1 : n - 2;
        foreach (i; firstJoint .. lastJoint + 1)
        {
            immutable d0 = dir[(i + segCount - 1) % segCount];
            immutable d1 = dir[i % segCount];
            addJoin(&emit, &arc, p[i], d0, d1, r, style.join, miterLimit);
        }

        // Caps.
        if (!sp.closed && style.cap != LineCap.butt)
        {
            foreach (end; 0 .. 2)
            {
                immutable pt = end == 0 ? p[0] : p[n - 1];
                immutable u = end == 0 ? Point(-dir[0].x, -dir[0].y) : dir[segCount - 1];
                immutable nrm = Point(-u.y * r, u.x * r);
                if (style.cap == LineCap.square)
                {
                    immutable ur = u * r;
                    emit([pt + nrm, pt + nrm + ur, pt - nrm + ur, pt - nrm]);
                }
                else
                {
                    auto half = arc(pt, atan2(u.y, u.x) + PI / 2, -PI);
                    emit(half);
                }
            }
        }
    }
    return pieces;
}

private double arcStep(double r, double tol)
{
    if (!(r > 0))
        return PI;
    immutable q = 1 - tol / r;
    if (q <= -1)
        return PI;
    immutable step = 2 * acos(q < 1 ? q : 1.0);
    return step < 1e-3 ? 1e-3 : (step > PI / 2 ? PI / 2 : step);
}

private void addJoin(void delegate(Polygon) emit, Point[] delegate(Point, double, double) arc,
        Point p, Point d0, Point d1, double r, LineJoin join, double miterLimit)
{
    immutable cross = d0.cross(d1);
    immutable dot = d0.dot(d1);
    if (cross == 0 && dot > 0)
        return;
    immutable s = cross > 0 ? 1.0 : -1.0;
    immutable A = Point(p.x + s * d0.y * r, p.y - s * d0.x * r);
    immutable B = Point(p.x + s * d1.y * r, p.y - s * d1.x * r);

    final switch (join)
    {
    case LineJoin.round:
        {
            immutable va = A - p, vb = B - p;
            double sweep = cross == 0 ? s * PI : atan2(va.cross(vb), va.dot(vb));
            auto pts = arc(p, atan2(va.y, va.x), sweep);
            emit([p] ~ pts);
        }
        break;
    case LineJoin.miter:
        {
            immutable ratio = 1 / sqrt((1 + dot) / 2);
            if (dot > -1 && cross != 0 && ratio <= miterLimit)
            {
                immutable t = (B - A).cross(d1) / cross;
                immutable m = A + d0 * t;
                emit([p, A, m, B]);
            }
            else
                emit([p, A, B]);
        }
        break;
    case LineJoin.bevel:
        emit([p, A, B]);
        break;
    }
}

/// Signed area of a polygon (positive for the orientation produced by
/// `strokeOutline`).
double signedArea(const Polygon poly)
{
    double a = 0;
    foreach (i; 0 .. poly.length)
    {
        immutable p = poly[i], q = poly[(i + 1) % poly.length];
        a += p.x * q.y - q.x * p.y;
    }
    return a / 2;
}

unittest
{
    import std.math : isClose;

    // A horizontal segment with butt caps is a 10 x 2 rectangle.
    Polyline pl;
    pl.points = [Point(0, 0), Point(10, 0)];
    auto polys = strokeOutline([pl], StrokeStyle(2), 0.01);
    double total = 0;
    foreach (q; polys)
    {
        assert(signedArea(q) > 0);
        total += signedArea(q);
    }
    assert(polys.length == 1 && isClose(total, 20));

    // Square caps extend by r at both ends.
    polys = strokeOutline([pl], StrokeStyle(2, LineCap.square), 0.01);
    assert(polys.length == 3);
}

unittest
{
    // A single-point subpath: nothing for butt, a disc for round, a square for square.
    Polyline pl;
    pl.points = [Point(5, 5), Point(5, 5)];
    assert(strokeOutline([pl], StrokeStyle(2), 0.01).length == 0);
    auto sq = strokeOutline([pl], StrokeStyle(2, LineCap.square), 0.01);
    assert(sq.length == 1 && abs(signedArea(sq[0]) - 4) < 1e-12);
    auto disc = strokeOutline([pl], StrokeStyle(2, LineCap.round), 0.001);
    assert(disc.length == 1 && abs(signedArea(disc[0]) - PI) < 0.01);
}

unittest
{
    // A right-angle corner: the miter join adds a unit square (r = 1) corner piece.
    Polyline pl;
    pl.points = [Point(0, 0), Point(10, 0), Point(10, 10)];
    auto miter = strokeOutline([pl], StrokeStyle(2, LineCap.butt, LineJoin.miter, 4), 0.01);
    auto bevel = strokeOutline([pl], StrokeStyle(2, LineCap.butt, LineJoin.bevel, 4), 0.01);
    assert(miter.length == 3 && bevel.length == 3);
    assert(abs(signedArea(miter[2]) - 1) < 1e-9); // quad p, A, M, B
    assert(abs(signedArea(bevel[2]) - 0.5) < 1e-9); // triangle p, A, B
    // Miter limit below sqrt(2) degrades to a bevel.
    auto low = strokeOutline([pl], StrokeStyle(2, LineCap.butt, LineJoin.miter, 1.2), 0.01);
    assert(abs(signedArea(low[2]) - 0.5) < 1e-9);
}
