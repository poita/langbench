module test_parse;

import std.math : abs, isClose;
import svgraster.buf;
import svgraster.colors;
import svgraster.geom;
import svgraster.parse;

private bool num(string s, double expect, size_t consumed)
{
    size_t p = 0;
    double v;
    return parseNumber(s, p, v) && isClose(v, expect, 1e-12, 1e-300) && p == consumed;
}

unittest // numbers
{
    assert(num("5", 5, 1));
    assert(num(".5", 0.5, 2));
    assert(num("5.", 5, 2));
    assert(num("-5.25", -5.25, 5));
    assert(num("+1e2", 100, 4));
    assert(num("1E-2x", 0.01, 4));
    assert(num("1e", 1, 1)); // exponent without digits is not part of the number
    assert(num("20.5.5e2", 20.5, 4));
    assert(num("0.1", 0.1, 3));
    assert(num("123456789012345678901234", 1.23456789012345678e23, 24));
    size_t p = 0;
    double v;
    assert(!parseNumber(".", p, v) && p == 0);
    assert(!parseNumber("-", p, v));
    assert(!parseNumber("e5", p, v));
}

unittest // lengths and opacities
{
    double v;
    assert(parseLength(" 12px ", v) && v == 12);
    assert(parseLength("3.5", v) && v == 3.5);
    assert(!parseLength("abc", v));
    assert(!parseLength("", v));
    assert(parseOpacity("0.5", v) && v == 0.5);
    assert(parseOpacity("50%", v) && v == 0.5);
    assert(parseOpacity("7", v) && v == 1);
    assert(parseOpacity("-2", v) && v == 0);
    assert(!parseOpacity("0.5px", v));
    assert(!parseOpacity("", v));
}

private uint rgb(string s, out bool ok)
{
    Paint p;
    ok = parsePaint(s, p) && p.kind == PaintKind.color;
    if (!ok)
        return 0;
    return (cast(uint) (p.r * 255 + 0.5) << 16) | (cast(uint) (p.g * 255 + 0.5) << 8) | cast(uint) (p.b * 255 + 0.5);
}

unittest // colours
{
    bool ok;
    assert(rgb("#f39", ok) == 0xff3399 && ok);
    assert(rgb("#12AB78", ok) == 0x12ab78 && ok);
    assert(rgb("rgb(10, 200, 30)", ok) == 0x0ac81e && ok);
    assert(rgb("rgb(300 -5 127.5)", ok) == 0xff0080 && ok);
    assert(rgb("rgb(20%, 45%, 90%)", ok) == 0x3373e6 && ok); // 51, 114.75 -> 115, 229.5 -> 230
    assert(rgb("DarkSlateGray", ok) == 0x2f4f4f && ok);
    assert(rgb("RED", ok) == 0xff0000 && ok);
    rgb("#ff", ok);
    assert(!ok);
    rgb("nosuchcolour", ok);
    assert(!ok);
    Paint p;
    assert(parsePaint("none", p) && p.kind == PaintKind.none);
    assert(parsePaint("currentColor", p) && p.kind == PaintKind.currentColor);
    assert(parsePaint("CURRENTCOLOR", p) && p.kind == PaintKind.currentColor);
}

unittest // the colour table
{
    assert(namedColors.length == 147);
    foreach (i; 1 .. namedColors.length)
        assert(namedColors[i - 1].name < namedColors[i].name);
    uint c;
    assert(lookupColor("rebeccapurple", c) == false); // CSS4 only
    assert(lookupColor("yellowgreen", c) && c == 0x9acd32);
    assert(lookupColor("aliceblue", c) && c == 0xf0f8ff);
}

private bool same(Matrix a, Matrix b)
{
    return isClose(a.a, b.a, 1e-12, 1e-12) && isClose(a.b, b.b, 1e-12, 1e-12)
        && isClose(a.c, b.c, 1e-12, 1e-12) && isClose(a.d, b.d, 1e-12, 1e-12)
        && isClose(a.e, b.e, 1e-12, 1e-12) && isClose(a.f, b.f, 1e-12, 1e-12);
}

unittest // transforms
{
    assert(same(parseTransform(""), Matrix.init));
    assert(same(parseTransform("translate(3)"), Matrix(1, 0, 0, 1, 3, 0)));
    assert(same(parseTransform("scale(2)"), Matrix(2, 0, 0, 2, 0, 0)));
    assert(same(parseTransform("matrix(1 2 3 4 5 6)"), Matrix(1, 2, 3, 4, 5, 6)));
    // left to right: the rightmost function applies to the coordinates first
    auto m = parseTransform("translate(10,0) scale(2)");
    assert(m.apply(Vec2(1, 1)) == Vec2(12, 2));
    auto r = parseTransform("rotate(90)");
    auto q = r.apply(Vec2(1, 0));
    assert(abs(q.x) < 1e-12 && abs(q.y - 1) < 1e-12);
    auto rc = parseTransform("rotate(90 5 5)").apply(Vec2(6, 5));
    assert(abs(rc.x - 5) < 1e-12 && abs(rc.y - 6) < 1e-12);
    assert(same(parseTransform("bogus(1) translate(1 2)"), Matrix(1, 0, 0, 1, 1, 2)));
    assert(same(parseTransform("matrix(1 2 3)"), Matrix.init));
    auto sk = parseTransform("skewX(45)");
    assert(abs(sk.c - 1) < 1e-12);
}

unittest // style declarations
{
    Buf!Decl d;
    parseStyle("fill : red;;stroke:blue; junk ;empty: ;Opacity:.5;", d);
    auto s = d.slice;
    assert(s.length == 3);
    assert(s[0].name == "fill" && s[0].value == "red");
    assert(s[1].name == "stroke" && s[1].value == "blue");
    assert(s[2].name == "Opacity" && equalsIgnoreCase(s[2].name, "opacity") && s[2].value == ".5");
}

unittest // number lists
{
    Buf!double b;
    parseNumberList(" 1,2 3 , -4.5e1 x 9", b);
    assert(b.slice == [1.0, 2, 3, -45]);
}
