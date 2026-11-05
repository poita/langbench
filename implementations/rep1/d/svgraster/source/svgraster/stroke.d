/// Stroke outlining (SPEC §8.2): a stroke is the union of per-segment
/// rectangles, join pieces and cap pieces, emitted as positively oriented
/// polygons that are filled together with the nonzero rule.
module svgraster.stroke;

import std.math : acos, atan2, ceil, cos, sin, sqrt, PI;
import svgraster.buf;
import svgraster.geom;
import svgraster.path;

/// Line cap styles.
enum LineCap : ubyte { butt, round, square }
/// Line join styles.
enum LineJoin : ubyte { miter, round, bevel }

/// Parameters of a stroke, in the coordinate system the outline is built in.
struct StrokeStyle
{
    double width = 1;
    LineCap cap = LineCap.butt;
    LineJoin join = LineJoin.miter;
    double miterLimit = 4;
}

/// A set of polygons stored in one point buffer. Piece `i` occupies
/// `pts[starts[i] .. starts[i+1]]` (the last piece ends at `pts.length`).
struct Outline
{
    Buf!Vec2 pts;
    Buf!size_t starts;

    /// Remove all pieces, keeping capacity.
    void clear() pure nothrow @safe
    {
        pts.clear();
        starts.clear();
    }

    /// Number of pieces.
    @property size_t pieces() const pure nothrow @nogc @safe { return starts.length; }

    /// The points of piece `i`.
    const(Vec2)[] piece(size_t i) const pure nothrow @nogc @safe
    {
        immutable b = starts.slice[i];
        immutable e = i + 1 < starts.length ? starts.slice[i + 1] : pts.length;
        return pts.slice[b .. e];
    }

    /// Transform every point by `m` in place.
    void transform(const Matrix m) pure nothrow @safe
    {
        foreach (ref p; pts.slice)
            p = m.apply(p);
    }

    private void begin() pure nothrow @safe { starts.push(pts.length); }

    private void add(Vec2 p) pure nothrow @safe { pts.push(p); }

    /// Finish the current piece: orient it to positive signed area.
    private void end() pure nothrow @safe
    {
        immutable b = starts[starts.length - 1];
        auto v = pts.slice[b .. $];
        if (v.length < 3)
        {
            pts.truncate(b);
            starts.truncate(starts.length - 1);
            return;
        }
        double area = 0;
        foreach (i; 0 .. v.length)
        {
            immutable q = v[(i + 1) % v.length];
            area += v[i].x * q.y - q.x * v[i].y;
        }
        if (area < 0)
        {
            foreach (i; 0 .. v.length / 2)
            {
                immutable t = v[i];
                v[i] = v[v.length - 1 - i];
                v[v.length - 1 - i] = t;
            }
        }
    }
}

/// Build the stroke outline of every subpath of `fp` (flattened in the
/// coordinate system of the stroke) into `o`. `tol` is the tolerance for
/// circular arcs in that same coordinate system.
void buildStroke(ref const FlatPath fp, const StrokeStyle st, double tol,
    ref Outline o, ref Buf!Vec2 scratch) pure nothrow @safe
{
    o.clear();
    immutable r = st.width / 2;
    foreach (sub; fp.subs.slice)
    {
        // Drop consecutive duplicates (and a final point equal to the first
        // for closed subpaths).
        scratch.clear();
        foreach (p; fp.points(sub))
        {
            if (scratch.length == 0 || scratch[scratch.length - 1] != p)
                scratch.push(p);
        }
        if (sub.closed && scratch.length > 1 && scratch[scratch.length - 1] == scratch[0])
            scratch.truncate(scratch.length - 1);
        auto p = scratch.slice;
        immutable n = p.length;
        if (n == 0)
            continue;
        if (n == 1)
        {
            pointPiece(o, p[0], r, st.cap, tol);
            continue;
        }
        immutable segs = sub.closed ? n : n - 1;
        foreach (i; 0 .. segs)
        {
            immutable a = p[i], b = p[(i + 1) % n];
            immutable d = unit(b.x - a.x, b.y - a.y);
            immutable nx = -d.y * r, ny = d.x * r;
            o.begin();
            o.add(Vec2(a.x + nx, a.y + ny));
            o.add(Vec2(b.x + nx, b.y + ny));
            o.add(Vec2(b.x - nx, b.y - ny));
            o.add(Vec2(a.x - nx, a.y - ny));
            o.end();
        }
        immutable firstJoint = sub.closed ? 0 : 1;
        immutable lastJoint = sub.closed ? n : n - 1; // exclusive
        foreach (i; firstJoint .. lastJoint)
        {
            immutable prev = p[(i + n - 1) % n], cur = p[i], next = p[(i + 1) % n];
            joinPiece(o, prev, cur, next, r, st, tol);
        }
        if (!sub.closed)
        {
            capPiece(o, p[0], unit(p[0].x - p[1].x, p[0].y - p[1].y), r, st.cap, tol);
            capPiece(o, p[n - 1], unit(p[n - 1].x - p[n - 2].x, p[n - 1].y - p[n - 2].y), r, st.cap, tol);
        }
    }
}

private Vec2 unit(double x, double y) pure nothrow @nogc @trusted
{
    immutable l = sqrt(x * x + y * y);
    return l > 0 ? Vec2(x / l, y / l) : Vec2(1, 0);
}

/// Angular step of a circular arc of radius `r` whose chords stay within `tol`.
private double arcStep(double r, double tol) pure nothrow @nogc @trusted
{
    immutable c = 1 - tol / r;
    if (!(c > -1))
        return PI;
    immutable s = 2 * acos(c);
    return s > 0 ? s : PI;
}

private int arcCount(double sweep, double step, int lo) pure nothrow @nogc @trusted
{
    immutable q = ceil((sweep < 0 ? -sweep : sweep) / step);
    int n = q > 2000 ? 2000 : cast(int) q;
    return n < lo ? lo : n;
}

private void pointPiece(ref Outline o, Vec2 p, double r, LineCap cap, double tol) pure nothrow @trusted
{
    final switch (cap)
    {
    case LineCap.butt:
        break;
    case LineCap.square:
        o.begin();
        o.add(Vec2(p.x - r, p.y - r));
        o.add(Vec2(p.x + r, p.y - r));
        o.add(Vec2(p.x + r, p.y + r));
        o.add(Vec2(p.x - r, p.y + r));
        o.end();
        break;
    case LineCap.round:
        {
            immutable step = arcStep(r, tol);
            immutable n = arcCount(2 * PI, step, 4);
            o.begin();
            foreach (i; 0 .. n)
            {
                immutable a = 2 * PI * i / n;
                o.add(Vec2(p.x + r * cos(a), p.y + r * sin(a)));
            }
            o.end();
        }
        break;
    }
}

private void capPiece(ref Outline o, Vec2 p, Vec2 u, double r, LineCap cap, double tol) pure nothrow @trusted
{
    immutable nx = -u.y * r, ny = u.x * r;
    final switch (cap)
    {
    case LineCap.butt:
        break;
    case LineCap.square:
        o.begin();
        o.add(Vec2(p.x + nx, p.y + ny));
        o.add(Vec2(p.x + nx + u.x * r, p.y + ny + u.y * r));
        o.add(Vec2(p.x - nx + u.x * r, p.y - ny + u.y * r));
        o.add(Vec2(p.x - nx, p.y - ny));
        o.end();
        break;
    case LineCap.round:
        {
            immutable step = arcStep(r, tol);
            immutable sweep = -PI; // from N (u rotated +90 degrees) round to -N via u
            immutable n = arcCount(sweep, step, 1);
            immutable a0 = atan2(ny, nx);
            o.begin();
            foreach (i; 0 .. n + 1)
            {
                immutable a = a0 + sweep * i / n;
                o.add(Vec2(p.x + r * cos(a), p.y + r * sin(a)));
            }
            o.end();
        }
        break;
    }
}

private void joinPiece(ref Outline o, Vec2 prev, Vec2 p, Vec2 next, double r,
    const StrokeStyle st, double tol) pure nothrow @trusted
{
    immutable d0 = unit(p.x - prev.x, p.y - prev.y);
    immutable d1 = unit(next.x - p.x, next.y - p.y);
    immutable cross = d0.x * d1.y - d0.y * d1.x;
    immutable dot = d0.x * d1.x + d0.y * d1.y;
    if (cross == 0 && dot > 0)
        return;
    immutable s = cross > 0 ? 1.0 : -1.0;
    immutable nax = s * d0.y, nay = -s * d0.x;
    immutable nbx = s * d1.y, nby = -s * d1.x;
    immutable A = Vec2(p.x + nax * r, p.y + nay * r);
    immutable B = Vec2(p.x + nbx * r, p.y + nby * r);

    final switch (st.join)
    {
    case LineJoin.round:
        {
            double sweep = cross == 0 ? s * PI : atan2(nax * nby - nay * nbx, nax * nbx + nay * nby);
            immutable step = arcStep(r, tol);
            immutable n = arcCount(sweep, step, 1);
            immutable a0 = atan2(nay, nax);
            o.begin();
            o.add(p);
            foreach (i; 0 .. n + 1)
            {
                immutable a = a0 + sweep * i / n;
                o.add(Vec2(p.x + r * cos(a), p.y + r * sin(a)));
            }
            o.end();
        }
        return;
    case LineJoin.miter:
        {
            immutable ratio = 1.0 / sqrt((1 + dot) / 2);
            double ml = st.miterLimit < 1 ? 1 : st.miterLimit;
            if (dot > -1 && cross != 0 && ratio <= ml)
            {
                immutable k = r / (1 + dot);
                immutable M = Vec2(p.x + (nax + nbx) * k, p.y + (nay + nby) * k);
                o.begin();
                o.add(p);
                o.add(A);
                o.add(M);
                o.add(B);
                o.end();
                return;
            }
        }
        goto case LineJoin.bevel;
    case LineJoin.bevel:
        o.begin();
        o.add(p);
        o.add(A);
        o.add(B);
        o.end();
        return;
    }
}
