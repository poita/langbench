/// Conversion of the basic SVG shapes to paths (SVG 1.1 §9, as profiled in
/// SPEC.md §7.3).
module svgraster.shapes;

import std.algorithm : min, max;
import svgraster.geom;
import svgraster.parse;
import svgraster.path;
import svgraster.pathdata;
import svgraster.xml;

/// The rendered shape elements.
bool isShape(string tag) pure nothrow @safe @nogc
{
    switch (tag)
    {
    case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
        return true;
    default:
        return false;
    }
}

/// The geometry of shape element `el` in its own user space. Elements that
/// draw nothing give an empty path.
Path shapeToPath(const Element el)
{
    Path p;
    double num(string name, double dflt = 0)
    {
        return lengthOr(el.get(name), dflt);
    }

    switch (el.tag)
    {
    case "path":
        return parsePathData(el.get("d"));
    case "rect":
        rectPath(p, num("x"), num("y"), num("width"), num("height"), el.get("rx"), el.get("ry"));
        break;
    case "circle":
        ellipsePath(p, num("cx"), num("cy"), num("r"), num("r"));
        break;
    case "ellipse":
        ellipsePath(p, num("cx"), num("cy"), num("rx"), num("ry"));
        break;
    case "line":
        p.moveTo(Point(num("x1"), num("y1")));
        p.lineTo(Point(num("x2"), num("y2")));
        break;
    case "polyline":
        return parsePoints(el.get("points"), false);
    case "polygon":
        return parsePoints(el.get("points"), true);
    default:
        break;
    }
    return p;
}

/// Append a (possibly rounded) rectangle. `rxAttr` and `ryAttr` are the raw
/// attribute values, or `null` when absent.
void rectPath(ref Path p, double x, double y, double w, double h, string rxAttr, string ryAttr)
{
    if (!(w > 0) || !(h > 0))
        return;
    double rx = 0, ry = 0;
    immutable hasRx = rxAttr !is null && rxAttr != "auto";
    immutable hasRy = ryAttr !is null && ryAttr != "auto";
    double rxv = hasRx ? lengthOr(rxAttr, 0) : 0;
    double ryv = hasRy ? lengthOr(ryAttr, 0) : 0;
    if (hasRx && hasRy)
    {
        rx = rxv;
        ry = ryv;
    }
    else if (hasRx)
        rx = ry = rxv;
    else if (hasRy)
        rx = ry = ryv;
    rx = max(rx, 0.0);
    ry = max(ry, 0.0);
    rx = min(rx, w / 2);
    ry = min(ry, h / 2);
    if (rx == 0 || ry == 0)
    {
        p.moveTo(Point(x, y));
        p.lineTo(Point(x + w, y));
        p.lineTo(Point(x + w, y + h));
        p.lineTo(Point(x, y + h));
        p.close();
        return;
    }
    p.moveTo(Point(x + rx, y));
    p.lineTo(Point(x + w - rx, y));
    p.arcTo(rx, ry, 0, false, true, Point(x + w, y + ry));
    p.lineTo(Point(x + w, y + h - ry));
    p.arcTo(rx, ry, 0, false, true, Point(x + w - rx, y + h));
    p.lineTo(Point(x + rx, y + h));
    p.arcTo(rx, ry, 0, false, true, Point(x, y + h - ry));
    p.lineTo(Point(x, y + ry));
    p.arcTo(rx, ry, 0, false, true, Point(x + rx, y));
    p.close();
}

/// Append an ellipse (nothing if a radius is not positive).
void ellipsePath(ref Path p, double cx, double cy, double rx, double ry)
{
    if (!(rx > 0) || !(ry > 0))
        return;
    p.moveTo(Point(cx + rx, cy));
    p.arcTo(rx, ry, 0, false, true, Point(cx, cy + ry));
    p.arcTo(rx, ry, 0, false, true, Point(cx - rx, cy));
    p.arcTo(rx, ry, 0, false, true, Point(cx, cy - ry));
    p.arcTo(rx, ry, 0, false, true, Point(cx + rx, cy));
    p.close();
}

unittest
{
    auto root = parseXml(`<svg>
        <rect x="1" y="2" width="3" height="4"/>
        <rect width="10" height="10" rx="3"/>
        <rect width="0" height="10"/>
        <circle cx="5" cy="5" r="2"/>
        <circle r="0"/>
        <line x1="1" y1="2" x2="3" y2="4"/>
    </svg>`);
    auto k = root.children;
    assert(shapeToPath(k[0]).segments.length == 5);
    const rounded = shapeToPath(k[1]);
    assert(rounded.segments.length > 9 && rounded.segments[0].p3 == Point(3, 0));
    assert(shapeToPath(k[2]).segments.length == 0);
    assert(shapeToPath(k[3]).segments.length > 5);
    assert(shapeToPath(k[4]).segments.length == 0);
    assert(shapeToPath(k[5]).segments.length == 2);
}
