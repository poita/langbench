/// Parser for the `d` attribute of `<path>` and for `points` lists.
module svgraster.pathdata;

import std.ascii : isAlpha;
import svgraster.geom;
import svgraster.parse;
import svgraster.path;

private bool isCommand(char c) pure nothrow @safe @nogc
{
    switch (c)
    {
    case 'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's',
         'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z':
        return true;
    default:
        return false;
    }
}

private bool readNumbers(const(char)[] s, ref size_t i, double[] out_)
{
    foreach (ref v; out_)
    {
        skipSeparators(s, i);
        if (!scanNumber(s, i, v))
            return false;
    }
    return true;
}

private bool readFlag(const(char)[] s, ref size_t i, out bool flag)
{
    skipSeparators(s, i);
    if (i < s.length && (s[i] == '0' || s[i] == '1'))
    {
        flag = s[i] == '1';
        ++i;
        return true;
    }
    return false;
}

/// Parse SVG path data. Parsing stops quietly at the first token that is not
/// what the grammar expects; everything parsed up to then is returned.
Path parsePathData(const(char)[] s)
{
    Path path;
    size_t i = 0;
    Point cur, start;
    Point lastCubicCtl, lastQuadCtl; // reflection sources
    bool prevCubic = false, prevQuad = false;
    bool first = true;

    while (true)
    {
        skipSeparators(s, i);
        if (i >= s.length)
            break;
        immutable cmd = s[i];
        if (!isCommand(cmd))
            break;
        if (first && cmd != 'M' && cmd != 'm')
            break;
        first = false;
        ++i;

        if (cmd == 'Z' || cmd == 'z')
        {
            path.close();
            cur = start;
            prevCubic = prevQuad = false;
            continue;
        }

        immutable rel = cmd >= 'a';
        char op = cmd;
        bool firstGroup = true;
        while (true)
        {
            if (!firstGroup)
            {
                skipSeparators(s, i);
                if (i >= s.length || isAlpha(s[i]))
                    break;
            }
            double[7] a;
            bool ok = true;
            immutable ox = rel ? cur.x : 0, oy = rel ? cur.y : 0;
            bool nextCubic = false, nextQuad = false;
            switch (op)
            {
            case 'M', 'm':
                ok = readNumbers(s, i, a[0 .. 2]);
                if (ok)
                {
                    cur = Point(a[0] + ox, a[1] + oy);
                    path.moveTo(cur);
                    start = cur;
                    op = rel ? 'l' : 'L'; // implicit repeats are line-tos
                }
                break;
            case 'L', 'l':
                ok = readNumbers(s, i, a[0 .. 2]);
                if (ok)
                {
                    cur = Point(a[0] + ox, a[1] + oy);
                    path.lineTo(cur);
                }
                break;
            case 'H', 'h':
                ok = readNumbers(s, i, a[0 .. 1]);
                if (ok)
                {
                    cur = Point(a[0] + ox, cur.y);
                    path.lineTo(cur);
                }
                break;
            case 'V', 'v':
                ok = readNumbers(s, i, a[0 .. 1]);
                if (ok)
                {
                    cur = Point(cur.x, a[0] + oy);
                    path.lineTo(cur);
                }
                break;
            case 'C', 'c':
                ok = readNumbers(s, i, a[0 .. 6]);
                if (ok)
                {
                    immutable c1 = Point(a[0] + ox, a[1] + oy);
                    immutable c2 = Point(a[2] + ox, a[3] + oy);
                    immutable e = Point(a[4] + ox, a[5] + oy);
                    path.cubicTo(c1, c2, e);
                    lastCubicCtl = c2;
                    nextCubic = true;
                    cur = e;
                }
                break;
            case 'S', 's':
                ok = readNumbers(s, i, a[0 .. 4]);
                if (ok)
                {
                    immutable c1 = prevCubic
                        ? Point(2 * cur.x - lastCubicCtl.x, 2 * cur.y - lastCubicCtl.y) : cur;
                    immutable c2 = Point(a[0] + ox, a[1] + oy);
                    immutable e = Point(a[2] + ox, a[3] + oy);
                    path.cubicTo(c1, c2, e);
                    lastCubicCtl = c2;
                    nextCubic = true;
                    cur = e;
                }
                break;
            case 'Q', 'q':
                ok = readNumbers(s, i, a[0 .. 4]);
                if (ok)
                {
                    immutable q = Point(a[0] + ox, a[1] + oy);
                    immutable e = Point(a[2] + ox, a[3] + oy);
                    quadTo(path, cur, q, e);
                    lastQuadCtl = q;
                    nextQuad = true;
                    cur = e;
                }
                break;
            case 'T', 't':
                ok = readNumbers(s, i, a[0 .. 2]);
                if (ok)
                {
                    immutable q = prevQuad
                        ? Point(2 * cur.x - lastQuadCtl.x, 2 * cur.y - lastQuadCtl.y) : cur;
                    immutable e = Point(a[0] + ox, a[1] + oy);
                    quadTo(path, cur, q, e);
                    lastQuadCtl = q;
                    nextQuad = true;
                    cur = e;
                }
                break;
            case 'A', 'a':
                {
                    bool large, sweep;
                    ok = readNumbers(s, i, a[0 .. 3]) && readFlag(s, i, large)
                        && readFlag(s, i, sweep) && readNumbers(s, i, a[3 .. 5]);
                    if (ok)
                    {
                        immutable e = Point(a[3] + ox, a[4] + oy);
                        path.arcTo(a[0], a[1], a[2], large, sweep, e);
                        cur = e;
                    }
                }
                break;
            default:
                assert(0);
            }
            if (!ok)
                return path;
            prevCubic = nextCubic;
            prevQuad = nextQuad;
            firstGroup = false;
        }
    }
    return path;
}

/// Append a quadratic Bézier as the equivalent cubic.
private void quadTo(ref Path path, Point c, Point q, Point e)
{
    immutable c1 = Point(c.x + 2.0 / 3.0 * (q.x - c.x), c.y + 2.0 / 3.0 * (q.y - c.y));
    immutable c2 = Point(e.x + 2.0 / 3.0 * (q.x - e.x), e.y + 2.0 / 3.0 * (q.y - e.y));
    path.cubicTo(c1, c2, e);
}

/// Parse a `points` attribute into a polyline or polygon path. An odd
/// trailing number is discarded; no points gives an empty path.
Path parsePoints(const(char)[] s, bool polygon)
{
    const nums = parseNumberList(s);
    Path p;
    foreach (k; 0 .. nums.length / 2)
    {
        immutable pt = Point(nums[2 * k], nums[2 * k + 1]);
        if (k == 0)
            p.moveTo(pt);
        else
            p.lineTo(pt);
    }
    if (polygon && p.segments.length > 0)
        p.close();
    return p;
}

unittest
{
    auto p = parsePathData("M10 10 20 20 h5 v-5 z");
    assert(p.segments.length == 5);
    assert(p.segments[1].kind == SegKind.line && p.segments[1].p3 == Point(20, 20));
    assert(p.segments[2].p3 == Point(25, 20));
    assert(p.segments[3].p3 == Point(25, 15));
    assert(p.segments[4].kind == SegKind.close);
}

unittest
{
    // Arc flags are single characters: "0110" is flag 0, flag 1, then 10.
    auto p = parsePathData("M0 0 a5 5 0 0110 10");
    assert(p.segments.length > 1);
    assert(p.current == Point(10, 10));
    // Stops at the first bad token but keeps what came before.
    p = parsePathData("M1 2 L3 4 L5 x L7 8");
    assert(p.segments.length == 2);
    // A number after Z ends parsing.
    p = parsePathData("M1 1 L2 2 Z 3 3");
    assert(p.segments.length == 3);
    // Must start with a move.
    assert(parsePathData("L1 1").segments.length == 0);
}

unittest
{
    // Smooth cubic reflects the previous control point.
    auto p = parsePathData("M0 0 C 0 10 10 10 10 0 S 20 -10 20 0");
    assert(p.segments[2].p1 == Point(10, -10));
    // Without a preceding C the control point is the current point.
    p = parsePathData("M0 0 L 5 5 S 10 10 20 0");
    assert(p.segments[2].p1 == Point(5, 5));
    // Quadratic elevation to a cubic.
    p = parsePathData("M0 0 Q 3 3 6 0");
    assert(p.segments[1].p1 == Point(2, 2) && p.segments[1].p2 == Point(4, 2));
    // T reflects the previous quadratic control point.
    p = parsePathData("M0 0 Q 3 3 6 0 T 12 0");
    assert(p.segments[2].p1 == Point(8, -2));
}

unittest
{
    assert(parsePoints("1,2 3,4 5", false).segments.length == 2);
    assert(parsePoints("1,2 3,4", true).segments.length == 3);
    assert(parsePoints("", true).segments.length == 0);
}
