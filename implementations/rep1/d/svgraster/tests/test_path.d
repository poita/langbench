module test_path;

import std.math : abs, PI, isClose;
import svgraster.geom;
import svgraster.path;
import svgraster.shapes;
import svgraster.xml;

private Path parse(string d)
{
    Path p;
    parsePathData(d, p);
    return p;
}

unittest // basic commands and relative forms
{
    auto p = parse("M10,10 20,40 40,10z m5 5 h10 v10");
    // M L L Z M L L
    assert(p.ops.slice == [Op.move, Op.line, Op.line, Op.close, Op.move, Op.line, Op.line]);
    // relative m after z starts from the closed subpath's start point (10,10)
    assert(p.pts.slice[3] == Vec2(15, 15));
    assert(p.pts.slice[4] == Vec2(25, 15));
    assert(p.pts.slice[5] == Vec2(25, 25));
}

unittest // parsing stops at the first unexpected token but keeps earlier commands
{
    auto p = parse("M150 80 L 170 80 L 170 95 L 150 95 bogus L 10 10");
    assert(p.ops.length == 4);
    p = parse("M5 102 L35 102 L35 110 Z 5 5");
    assert(p.ops.slice == [Op.move, Op.line, Op.line, Op.close]);
    p = parse("M1 1 L 2");
    assert(p.ops.slice == [Op.move]);
    assert(parse("L 1 1").empty);
    assert(parse("").empty);
}

unittest // numbers glued together and implicit lineto
{
    auto p = parse("M.5 90 L 1e1 95 L 20.5.5e2 Z");
    assert(p.pts.slice[2] == Vec2(20.5, 50));
    p = parse("M0 0 10 10 20 0");
    assert(p.ops.slice == [Op.move, Op.line, Op.line]);
}

unittest // S/T reflection and Q as cubic
{
    auto p = parse("M0 0 C 0 10 10 10 10 0 S 20 -10 20 0");
    assert(p.pts.slice[4] == Vec2(10, -10)); // reflected first control point
    p = parse("M0 0 L 10 0 S 20 5 20 0"); // previous was not a cubic: control = current point
    assert(p.pts.slice[2] == Vec2(10, 0));
    p = parse("M0 0 Q 3 6 6 0");
    assert(p.ops.slice == [Op.move, Op.cubic]);
    assert(p.pts.slice[1] == Vec2(2, 4) && p.pts.slice[2] == Vec2(4, 4));
    p = parse("M0 0 Q 3 6 6 0 T 12 0");
    assert(p.pts.slice[4] == Vec2(8, -4));
}

unittest // arc flags are single characters
{
    auto p = parse("M0 0 a5 5 0 0110 10");
    assert(p.ops.length >= 2 && p.ops.slice[1] == Op.cubic);
    assert(p.pts.slice[$ - 1] == Vec2(10, 10));
    // coincident endpoints drop the arc; zero radius gives a line
    assert(parse("M1 1 A5 5 0 0 1 1 1").ops.length == 1);
    assert(parse("M0 0 A0 5 0 0 1 4 4").ops.slice == [Op.move, Op.line]);
}

unittest // arcs end exactly at the requested point and stay on the circle
{
    Path p;
    p.moveTo(Vec2(10, 0));
    arcTo(p, Vec2(10, 0), 10, 10, 0, false, true, Vec2(0, 10));
    assert(p.pts.slice[$ - 1] == Vec2(0, 10));
    FlatPath f;
    flatten(p, Matrix.init, 0.01, f);
    foreach (q; f.points(f.subs[0]))
        assert(abs(q.x * q.x + q.y * q.y - 100) < 0.2);
    // radii too small are scaled up: a half circle of radius 5
    Path h;
    h.moveTo(Vec2(0, 0));
    arcTo(h, Vec2(0, 0), 1, 1, 0, false, true, Vec2(10, 0));
    flatten(h, Matrix.init, 0.01, f);
    double ymax = 0;
    foreach (q; f.points(f.subs[0]))
        if (abs(q.y) > ymax)
            ymax = abs(q.y);
    assert(abs(ymax - 5) < 0.01);
}

unittest // flattening rules for subpaths
{
    FlatPath f;
    flatten(parse("M10 10"), Matrix.init, 0.01, f);
    assert(f.subs.length == 0); // lone M is not a subpath
    flatten(parse("M10 10 Z"), Matrix.init, 0.01, f);
    assert(f.subs.length == 1 && f.subs[0].closed && f.subs[0].end - f.subs[0].begin == 1);
    flatten(parse("M0 0 L5 0 L5 5 Z L 9 9"), Matrix.init, 0.01, f);
    assert(f.subs.length == 2 && f.subs[0].closed && !f.subs[1].closed);
    assert(f.points(f.subs[1])[0] == Vec2(0, 0)); // continues from the closed start
    flatten(parse("M0 0 L 1 1"), Matrix.scale(2, 3), 0.01, f);
    assert(f.points(f.subs[0])[1] == Vec2(2, 3));
}

unittest // cubic step count follows the reference rule
{
    // straight cubic: one step
    assert(cubicSteps(Vec2(0, 0), Vec2(1, 0), Vec2(2, 0), Vec2(3, 0), 0.01) == 1);
    // m = |P0 - 2P1 + P2|^2 = 100^2 -> n = ceil(sqrt(0.75 * 100 / 0.01)) = 87
    assert(cubicSteps(Vec2(0, 0), Vec2(0, 50), Vec2(0, 0), Vec2(0, 0), 0.01) == 87);
    assert(cubicSteps(Vec2(0, 0), Vec2(1e9, 0), Vec2(0, 0), Vec2(0, 0), 0.01) == 1000);
}

private Element el(string xml)
{
    return parseXml(xml).root;
}

unittest // shapes
{
    Path p;
    assert(!shapeToPath(el(`<rect width="0" height="5"/>`), p));
    assert(!shapeToPath(el(`<circle r="0"/>`), p));
    assert(!shapeToPath(el(`<ellipse rx="3"/>`), p));
    assert(!shapeToPath(el(`<polygon points=""/>`), p));
    assert(shapeToPath(el(`<rect x="1" y="2" width="3" height="4"/>`), p));
    assert(p.ops.slice == [Op.move, Op.line, Op.line, Op.line, Op.close]);
    p.clear();
    assert(shapeToPath(el(`<rect width="10" height="10" rx="3"/>`), p)); // ry takes rx
    FlatPath f;
    flatten(p, Matrix.init, 0.01, f);
    assert(f.subs.length == 1);
    // rx larger than half the width is clamped, giving a pill
    p.clear();
    shapeToPath(el(`<rect width="10" height="4" rx="50" ry="auto"/>`), p);
    flatten(p, Matrix.init, 0.01, f);
    double minx = 1e9, maxy = -1e9;
    foreach (q; f.points(f.subs[0]))
    {
        if (q.x < minx) minx = q.x;
        if (q.y > maxy) maxy = q.y;
    }
    assert(minx == 0 && abs(maxy - 4) < 1e-9);
    p.clear();
    shapeToPath(el(`<polyline points="1,2 3,4 5"/>`), p);
    assert(p.ops.slice == [Op.move, Op.line]);
    p.clear();
    shapeToPath(el(`<polygon points="0 0 1 0 1 1"/>`), p);
    assert(p.ops.slice == [Op.move, Op.line, Op.line, Op.close]);
    p.clear();
    shapeToPath(el(`<line x2="5"/>`), p);
    assert(p.pts.slice == [Vec2(0, 0), Vec2(5, 0)]);
    p.clear();
    shapeToPath(el(`<circle cx="5" cy="5" r="2"/>`), p);
    assert(p.pts.slice[0] == Vec2(7, 5));
    assert(p.ops.slice[$ - 1] == Op.close);
}
