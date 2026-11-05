/// Path model (`M`/`L`/`C`/`Z` segments), the path-data parser, elliptical
/// arc conversion and curve flattening.
module svgraster.path;

import std.math : abs, atan2, ceil, cos, sin, sqrt, tan, PI;
import svgraster.buf;
import svgraster.geom;
import svgraster.parse;

/// Segment kinds stored in a `Path`.
enum Op : ubyte
{
    move,  /// `M`: 1 point
    line,  /// `L`: 1 point
    cubic, /// `C`: 3 points
    close, /// `Z`: no points
}

/// A path made only of move, line, cubic and close segments.
struct Path
{
    Buf!Op ops;
    Buf!Vec2 pts;

    /// Remove all segments, keeping capacity.
    void clear() pure nothrow @safe
    {
        ops.clear();
        pts.clear();
    }

    /// True when the path has no segments.
    @property bool empty() const pure nothrow @nogc @safe { return ops.length == 0; }

    /// Start a new subpath.
    void moveTo(Vec2 p) pure nothrow @safe
    {
        ops.push(Op.move);
        pts.push(p);
    }

    /// Straight line to `p`.
    void lineTo(Vec2 p) pure nothrow @safe
    {
        ops.push(Op.line);
        pts.push(p);
    }

    /// Cubic Bézier with control points `c1`, `c2` ending at `p`.
    void cubicTo(Vec2 c1, Vec2 c2, Vec2 p) pure nothrow @safe
    {
        ops.push(Op.cubic);
        pts.push(c1);
        pts.push(c2);
        pts.push(p);
    }

    /// Close the current subpath.
    void close() pure nothrow @safe
    {
        ops.push(Op.close);
    }
}

/// Append the cubic approximation of an elliptical arc from `p0` to `p1`
/// (SVG 1.1 implementation notes F.6.5/F.6.6, SPEC §7.5). `phiDeg` is the
/// x-axis rotation in degrees.
void arcTo(ref Path path, Vec2 p0, double rx, double ry, double phiDeg,
    bool largeArc, bool sweep, Vec2 p1) @trusted pure nothrow
{
    if (p0.x == p1.x && p0.y == p1.y)
        return;
    rx = abs(rx);
    ry = abs(ry);
    if (rx == 0 || ry == 0)
    {
        path.lineTo(p1);
        return;
    }
    immutable phi = phiDeg * PI / 180.0;
    immutable cp = cos(phi), sp = sin(phi);
    immutable dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2;
    immutable x1p = cp * dx + sp * dy;
    immutable y1p = -sp * dx + cp * dy;
    immutable lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
    if (lambda > 1)
    {
        immutable s = sqrt(lambda);
        rx *= s;
        ry *= s;
    }
    immutable rx2 = rx * rx, ry2 = ry * ry;
    immutable num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
    immutable den = rx2 * y1p * y1p + ry2 * x1p * x1p;
    double coef = den == 0 ? 0 : sqrt(num / den > 0 ? num / den : 0);
    if (largeArc == sweep)
        coef = -coef;
    immutable cxp = coef * rx * y1p / ry;
    immutable cyp = -coef * ry * x1p / rx;
    immutable cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2;
    immutable cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2;
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

    Vec2 ellipse(double t)
    {
        immutable ex = rx * cos(t), ey = ry * sin(t);
        return Vec2(cx + cp * ex - sp * ey, cy + sp * ex + cp * ey);
    }
    Vec2 tangent(double t)
    {
        immutable ex = -rx * sin(t), ey = ry * cos(t);
        return Vec2(cp * ex - sp * ey, sp * ex + cp * ey);
    }

    foreach (i; 0 .. n)
    {
        immutable t0 = theta1 + i * delta, t1 = t0 + delta;
        immutable e0 = ellipse(t0), e1 = ellipse(t1);
        immutable d0 = tangent(t0), d1 = tangent(t1);
        Vec2 c1 = Vec2(e0.x + k * d0.x, e0.y + k * d0.y);
        Vec2 c2 = Vec2(e1.x - k * d1.x, e1.y - k * d1.y);
        Vec2 end = (i == n - 1) ? p1 : e1;
        path.cubicTo(c1, c2, end);
    }
}

/// Parse SVG path data (SPEC §7.4) and append the result to `path`. Parsing
/// stops at the first unexpected token; everything parsed before it is kept.
void parsePathData(const(char)[] d, ref Path path) @safe pure nothrow
{
    size_t p = 0;
    Vec2 cur, start, lastCtrl;
    char prevKind = 0; // 'C' after C/S, 'Q' after Q/T, else 0
    char cmd = 0;
    bool seenMove = false;

    bool num(out double v)
    {
        skipSpaceComma(d, p);
        return parseNumber(d, p, v);
    }
    bool flag(out bool v)
    {
        skipSpaceComma(d, p);
        if (p < d.length && (d[p] == '0' || d[p] == '1'))
        {
            v = d[p] == '1';
            ++p;
            return true;
        }
        return false;
    }

    for (;;)
    {
        skipSpaceComma(d, p);
        if (p >= d.length)
            return;
        immutable c = d[p];
        if (isCommandLetter(c))
        {
            cmd = c;
            ++p;
            if (cmd == 'Z' || cmd == 'z')
            {
                if (seenMove)
                {
                    path.close();
                    cur = start;
                }
                prevKind = 0;
                cmd = 0;
                continue;
            }
        }
        else if (!(isNumberStart(c) && cmd != 0))
            return;

        if (!seenMove && cmd != 'M' && cmd != 'm')
            return;

        immutable rel = cmd >= 'a';
        immutable ox = rel ? cur.x : 0.0;
        immutable oy = rel ? cur.y : 0.0;
        double x1, y1, x2, y2, x, y;
        switch (cmd)
        {
        case 'M':
        case 'm':
            if (!num(x) || !num(y))
                return;
            cur = start = Vec2(ox + x, oy + y);
            path.moveTo(cur);
            seenMove = true;
            cmd = rel ? 'l' : 'L';
            prevKind = 0;
            break;
        case 'L':
        case 'l':
            if (!num(x) || !num(y))
                return;
            cur = Vec2(ox + x, oy + y);
            path.lineTo(cur);
            prevKind = 0;
            break;
        case 'H':
        case 'h':
            if (!num(x))
                return;
            cur = Vec2(ox + x, cur.y);
            path.lineTo(cur);
            prevKind = 0;
            break;
        case 'V':
        case 'v':
            if (!num(y))
                return;
            cur = Vec2(cur.x, oy + y);
            path.lineTo(cur);
            prevKind = 0;
            break;
        case 'C':
        case 'c':
            if (!num(x1) || !num(y1) || !num(x2) || !num(y2) || !num(x) || !num(y))
                return;
            lastCtrl = Vec2(ox + x2, oy + y2);
            path.cubicTo(Vec2(ox + x1, oy + y1), lastCtrl, Vec2(ox + x, oy + y));
            cur = Vec2(ox + x, oy + y);
            prevKind = 'C';
            break;
        case 'S':
        case 's':
            if (!num(x2) || !num(y2) || !num(x) || !num(y))
                return;
            {
                Vec2 c1 = prevKind == 'C' ? Vec2(2 * cur.x - lastCtrl.x, 2 * cur.y - lastCtrl.y) : cur;
                lastCtrl = Vec2(ox + x2, oy + y2);
                path.cubicTo(c1, lastCtrl, Vec2(ox + x, oy + y));
                cur = Vec2(ox + x, oy + y);
                prevKind = 'C';
            }
            break;
        case 'Q':
        case 'q':
            if (!num(x1) || !num(y1) || !num(x) || !num(y))
                return;
            quadTo(path, cur, Vec2(ox + x1, oy + y1), Vec2(ox + x, oy + y));
            lastCtrl = Vec2(ox + x1, oy + y1);
            cur = Vec2(ox + x, oy + y);
            prevKind = 'Q';
            break;
        case 'T':
        case 't':
            if (!num(x) || !num(y))
                return;
            {
                Vec2 q = prevKind == 'Q' ? Vec2(2 * cur.x - lastCtrl.x, 2 * cur.y - lastCtrl.y) : cur;
                quadTo(path, cur, q, Vec2(ox + x, oy + y));
                lastCtrl = q;
                cur = Vec2(ox + x, oy + y);
                prevKind = 'Q';
            }
            break;
        case 'A':
        case 'a':
            {
                double rx, ry, rot;
                bool large, sweep;
                if (!num(rx) || !num(ry) || !num(rot) || !flag(large) || !flag(sweep) || !num(x) || !num(y))
                    return;
                Vec2 end = Vec2(ox + x, oy + y);
                arcTo(path, cur, rx, ry, rot, large, sweep, end);
                cur = end;
                prevKind = 0;
            }
            break;
        default:
            return;
        }
        // A subpath that continues after a close starts at the old start point;
        // `cur` already equals `start` in that case.
    }
}

private bool isCommandLetter(char c) pure nothrow @nogc @safe
{
    switch (c)
    {
    case 'M': case 'm': case 'L': case 'l': case 'H': case 'h': case 'V': case 'v':
    case 'C': case 'c': case 'S': case 's': case 'Q': case 'q': case 'T': case 't':
    case 'A': case 'a': case 'Z': case 'z':
        return true;
    default:
        return false;
    }
}

private void quadTo(ref Path path, Vec2 c, Vec2 q, Vec2 e) pure nothrow @safe
{
    path.cubicTo(Vec2(c.x + 2.0 / 3.0 * (q.x - c.x), c.y + 2.0 / 3.0 * (q.y - c.y)),
        Vec2(e.x + 2.0 / 3.0 * (q.x - e.x), e.y + 2.0 / 3.0 * (q.y - e.y)), e);
}

/// A flattened subpath: indices into `FlatPath.pts`.
struct SubPath
{
    size_t begin; /// first point
    size_t end;   /// one past the last point
    bool closed;  /// ended with `Z`
}

/// A path flattened into polylines.
struct FlatPath
{
    Buf!Vec2 pts;
    Buf!SubPath subs;

    /// Remove everything, keeping capacity.
    void clear() pure nothrow @safe
    {
        pts.clear();
        subs.clear();
    }

    /// The points of subpath `s`.
    const(Vec2)[] points(const SubPath s) const pure nothrow @nogc @safe
    {
        return pts.slice[s.begin .. s.end];
    }
}

/// Number of equal parameter steps used to flatten a cubic with the given
/// control points to within `tol` (SPEC §7.6).
int cubicSteps(Vec2 p0, Vec2 p1, Vec2 p2, Vec2 p3, double tol) pure nothrow @nogc @trusted
{
    immutable ax = p0.x - 2 * p1.x + p2.x, ay = p0.y - 2 * p1.y + p2.y;
    immutable bx = p1.x - 2 * p2.x + p3.x, by = p1.y - 2 * p2.y + p3.y;
    immutable a2 = ax * ax + ay * ay, b2 = bx * bx + by * by;
    immutable m = a2 > b2 ? a2 : b2;
    immutable v = sqrt(0.75 * sqrt(m) / tol);
    if (!(v == v)) // NaN
        return 1;
    if (v >= 1000)
        return 1000;
    int n = cast(int) ceil(v);
    return n < 1 ? 1 : n;
}

/// Flatten `path` into `outPath`, transforming every control point by `m`
/// first and subdividing cubics to within `tol` (in the transformed space).
///
/// A subpath starts at an `M` that is followed by at least one drawing
/// command (a lone `M` contributes nothing). `M Z` yields a one-point closed
/// subpath. A drawing command after `Z` starts a new subpath at the start
/// point of the closed one.
void flatten(const Path path, const Matrix m, double tol, ref FlatPath outPath) pure nothrow @safe
{
    outPath.clear();
    Vec2 cur, start;
    bool active = false, haveMove = false;
    size_t subBegin = 0;
    size_t pi = 0;

    void endSub(bool closed)
    {
        outPath.subs.push(SubPath(subBegin, outPath.pts.length, closed));
        active = false;
    }
    void ensureSub()
    {
        if (!active)
        {
            subBegin = outPath.pts.length;
            outPath.pts.push(cur);
            active = true;
            haveMove = false;
        }
    }

    foreach (op; path.ops.slice)
    {
        final switch (op)
        {
        case Op.move:
            if (active)
                endSub(false);
            cur = start = m.apply(path.pts.slice[pi++]);
            haveMove = true;
            break;
        case Op.line:
            ensureSub();
            cur = m.apply(path.pts.slice[pi++]);
            outPath.pts.push(cur);
            break;
        case Op.cubic:
            {
                ensureSub();
                immutable c1 = m.apply(path.pts.slice[pi]);
                immutable c2 = m.apply(path.pts.slice[pi + 1]);
                immutable e = m.apply(path.pts.slice[pi + 2]);
                pi += 3;
                immutable n = cubicSteps(cur, c1, c2, e, tol);
                foreach (i; 1 .. n)
                {
                    immutable t = cast(double) i / n;
                    immutable u = 1 - t;
                    immutable w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t;
                    outPath.pts.push(Vec2(w0 * cur.x + w1 * c1.x + w2 * c2.x + w3 * e.x,
                        w0 * cur.y + w1 * c1.y + w2 * c2.y + w3 * e.y));
                }
                outPath.pts.push(e);
                cur = e;
            }
            break;
        case Op.close:
            if (active)
                endSub(true);
            else if (haveMove)
            {
                subBegin = outPath.pts.length;
                outPath.pts.push(start);
                endSub(true);
                haveMove = false;
            }
            cur = start;
            break;
        }
    }
    if (active)
        endSub(false);
}
