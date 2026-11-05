module test_raster;

import std.math : abs, isClose, PI;
import svgraster.buf;
import svgraster.geom;
import svgraster.path;
import svgraster.raster;
import svgraster.stroke;

private double alphaAt(Canvas c, int x, int y)
{
    return c.px[(y * c.width + x) * 4 + 3];
}

private immutable Vec2[] square = [Vec2(1, 1), Vec2(4.5, 1), Vec2(4.5, 3), Vec2(1, 3)];

unittest // fractional rectangle edge gives exact coverage
{
    auto c = new Canvas(8, 4);
    auto r = new Rasterizer(8, 4);
    r.begin();
    r.addPolygon(square);
    r.fill(c, FillRule.nonzero, 0, 0, 1, 1.0);
    assert(alphaAt(c, 0, 1) == 0);
    assert(alphaAt(c, 1, 1) == 1);
    assert(alphaAt(c, 3, 2) == 1);
    assert(alphaAt(c, 4, 1) == 0.5);
    assert(alphaAt(c, 5, 1) == 0);
    assert(alphaAt(c, 2, 0) == 0 && alphaAt(c, 2, 3) == 0);
    assert(c.rowLo == 1 && c.rowHi == 2);
    auto rgb = c.toRgb8();
    auto px = rgb[(1 * 8 + 4) * 3 .. (1 * 8 + 4) * 3 + 3];
    assert(px == [cast(ubyte) 0x80, 0x80, 0xff]);
    px = rgb[0 .. 3];
    assert(px == [cast(ubyte) 255, 255, 255]);
}

unittest // winding rules on a five-pointed star
{
    immutable Vec2[] star = [Vec2(10, 0), Vec2(16, 18), Vec2(0, 7), Vec2(20, 7), Vec2(4, 18)];
    auto a = new Canvas(20, 20), b = new Canvas(20, 20);
    auto r = new Rasterizer(20, 20);
    r.begin();
    r.addPolygon(star);
    r.fill(a, FillRule.nonzero, 0, 0, 0, 1);
    r.fill(b, FillRule.evenodd, 0, 0, 0, 1);
    assert(alphaAt(a, 10, 9) == 1); // centre pentagon: winding 2
    assert(alphaAt(b, 10, 9) == 0);
    assert(alphaAt(a, 10, 3) == 1 && alphaAt(b, 10, 3) == 1); // a tip
}

unittest // clipping to the canvas and opposite orientation
{
    auto c = new Canvas(4, 4);
    auto r = new Rasterizer(4, 4);
    r.begin();
    r.addPolygon([Vec2(-10, -10), Vec2(-10, 10), Vec2(10, 10), Vec2(10, -10)]); // clockwise on screen
    r.fill(c, FillRule.nonzero, 1, 0, 0, 0.5);
    foreach (y; 0 .. 4)
        foreach (x; 0 .. 4)
            assert(alphaAt(c, x, y) == 0.5);
    // a polygon entirely outside paints nothing
    auto d = new Canvas(4, 4);
    r.begin();
    r.addPolygon([Vec2(10, 10), Vec2(20, 10), Vec2(20, 20)]);
    r.fill(d, FillRule.nonzero, 1, 0, 0, 1);
    assert(d.rowHi < d.rowLo);
}

unittest // source-over compositing and group opacity
{
    auto c = new Canvas(1, 1);
    auto r = new Rasterizer(1, 1);
    immutable Vec2[] full = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)];
    r.begin();
    r.addPolygon(full);
    r.fill(c, FillRule.nonzero, 1, 0, 0, 0.5);
    r.fill(c, FillRule.nonzero, 0, 0, 1, 0.5);
    assert(isClose(c.px[0], 0.25) && isClose(c.px[2], 0.5) && isClose(c.px[3], 0.75));

    auto layer = new Canvas(1, 1);
    r.fill(layer, FillRule.nonzero, 0, 1, 0, 1);
    auto base = new Canvas(1, 1);
    base.compositeLayer(layer, 0.5);
    assert(isClose(base.px[1], 0.5) && isClose(base.px[3], 0.5));
    layer.clear();
    assert(layer.px[3] == 0 && layer.rowHi < layer.rowLo);
}

private double area(const(Vec2)[] p)
{
    double a = 0;
    foreach (i; 0 .. p.length)
    {
        auto q = p[(i + 1) % p.length];
        a += p[i].x * q.y - q.x * p[i].y;
    }
    return a / 2;
}

private Outline stroke(string d, StrokeStyle st, double tol = 0.01)
{
    Path p;
    parsePathData(d, p);
    FlatPath f;
    flatten(p, Matrix.init, tol, f);
    Outline o;
    Buf!Vec2 scratch;
    buildStroke(f, st, tol, o, scratch);
    return o;
}

unittest // pieces are positively oriented; segment rectangles and caps
{
    StrokeStyle st;
    st.width = 2;
    auto o = stroke("M0 0 L10 0", st);
    assert(o.pieces == 1);
    assert(isClose(area(o.piece(0)), 20));
    st.cap = LineCap.square;
    o = stroke("M0 0 L10 0", st);
    assert(o.pieces == 3);
    foreach (i; 0 .. o.pieces)
        assert(area(o.piece(i)) > 0);
    st.cap = LineCap.round;
    o = stroke("M0 0 L10 0", st);
    assert(o.pieces == 3);
    assert(abs(area(o.piece(1)) - PI / 2) < 0.03);
}

unittest // joins
{
    StrokeStyle st;
    st.width = 2;
    // right angle: miter adds a quadrilateral p, A, M, B of area 1 (a unit square)
    auto o = stroke("M0 0 L10 0 L10 10", st);
    assert(o.pieces == 3);
    assert(isClose(area(o.piece(2)), 1.0));
    st.join = LineJoin.bevel;
    o = stroke("M0 0 L10 0 L10 10", st);
    assert(isClose(area(o.piece(2)), 0.5));
    st.join = LineJoin.round;
    o = stroke("M0 0 L10 0 L10 10", st);
    assert(abs(area(o.piece(2)) - PI / 4) < 0.02);
    // a sharp angle beyond the miter limit falls back to a bevel
    st.join = LineJoin.miter;
    st.miterLimit = 4;
    o = stroke("M0 0 L10 0 L0 1", st);
    assert(o.piece(2).length == 3);
    // collinear continuation has no join piece
    o = stroke("M0 0 L5 0 L10 0", st);
    assert(o.pieces == 2);
    // a closed square has four joints
    o = stroke("M0 0 L10 0 L10 10 L0 10 Z", st);
    assert(o.pieces == 8);
}

unittest // reversal and degenerate subpaths
{
    StrokeStyle st;
    st.width = 2;
    st.join = LineJoin.round;
    auto o = stroke("M0 0 L10 0 L0 0", st);
    assert(o.pieces == 3);
    // the half disc lies beyond the turning point, at x > 10
    foreach (p; o.piece(2))
        assert(p.x >= 10 - 1e-9);
    // single points
    st.cap = LineCap.butt;
    assert(stroke("M5 5 L5 5", st).pieces == 0);
    st.cap = LineCap.square;
    o = stroke("M5 5 Z", st);
    assert(o.pieces == 1 && isClose(area(o.piece(0)), 4));
    st.cap = LineCap.round;
    o = stroke("M5 5 L5 5", st);
    assert(o.pieces == 1 && abs(area(o.piece(0)) - PI) < 0.06);
    assert(stroke("M5 5", st).pieces == 0);
}
