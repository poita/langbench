/// Conversion of SVG basic shapes into paths (SPEC §7.3).
module svgraster.shapes;

import std.algorithm.comparison : min;
import svgraster.buf;
import svgraster.geom;
import svgraster.parse;
import svgraster.path;
import svgraster.xml;

/// True if `tag` names one of the seven shape elements (or `path`).
bool isShapeTag(string tag) pure nothrow @nogc @safe
{
    return tag == "path" || tag == "rect" || tag == "circle" || tag == "ellipse"
        || tag == "line" || tag == "polyline" || tag == "polygon";
}

private double lengthAttr(const Element e, string name, double dflt) pure nothrow @safe
{
    double v;
    if (e.has(name) && parseLength(e.attr(name), v))
        return v;
    return dflt;
}

/// Append the path for shape element `e` to `path` (which should be empty).
/// Returns false, leaving the path empty, when the element draws nothing.
bool shapeToPath(const Element e, ref Path path) pure nothrow @safe
{
    switch (e.tag)
    {
    case "path":
        parsePathData(e.attr("d"), path);
        break;
    case "rect":
        rectPath(e, path);
        break;
    case "circle":
        {
            immutable r = lengthAttr(e, "r", 0);
            if (r > 0)
                ellipsePath(path, lengthAttr(e, "cx", 0), lengthAttr(e, "cy", 0), r, r);
        }
        break;
    case "ellipse":
        {
            immutable rx = lengthAttr(e, "rx", 0), ry = lengthAttr(e, "ry", 0);
            if (rx > 0 && ry > 0)
                ellipsePath(path, lengthAttr(e, "cx", 0), lengthAttr(e, "cy", 0), rx, ry);
        }
        break;
    case "line":
        path.moveTo(Vec2(lengthAttr(e, "x1", 0), lengthAttr(e, "y1", 0)));
        path.lineTo(Vec2(lengthAttr(e, "x2", 0), lengthAttr(e, "y2", 0)));
        break;
    case "polyline":
    case "polygon":
        {
            Buf!double nums;
            parseNumberList(e.attr("points"), nums);
            immutable n = nums.length / 2;
            auto v = nums.slice;
            foreach (i; 0 .. n)
            {
                auto pt = Vec2(v[2 * i], v[2 * i + 1]);
                if (i == 0)
                    path.moveTo(pt);
                else
                    path.lineTo(pt);
            }
            if (n >= 1 && e.tag == "polygon")
                path.close();
        }
        break;
    default:
        break;
    }
    return !path.empty;
}

private void rectPath(const Element e, ref Path path) pure nothrow @safe
{
    immutable x = lengthAttr(e, "x", 0), y = lengthAttr(e, "y", 0);
    immutable w = lengthAttr(e, "width", 0), h = lengthAttr(e, "height", 0);
    if (!(w > 0) || !(h > 0))
        return;
    double rx = 0, ry = 0;
    double v;
    immutable hasRx = e.has("rx") && e.attr("rx") != "auto" && parseLength(e.attr("rx"), v);
    if (hasRx)
        rx = v;
    immutable hasRy = e.has("ry") && e.attr("ry") != "auto" && parseLength(e.attr("ry"), v);
    if (hasRy)
        ry = v;
    if (hasRx && !hasRy)
        ry = rx;
    else if (hasRy && !hasRx)
        rx = ry;
    if (rx < 0)
        rx = 0;
    if (ry < 0)
        ry = 0;
    rx = min(rx, w / 2);
    ry = min(ry, h / 2);
    if (rx == 0 || ry == 0)
    {
        path.moveTo(Vec2(x, y));
        path.lineTo(Vec2(x + w, y));
        path.lineTo(Vec2(x + w, y + h));
        path.lineTo(Vec2(x, y + h));
        path.close();
        return;
    }
    path.moveTo(Vec2(x + rx, y));
    path.lineTo(Vec2(x + w - rx, y));
    arcTo(path, Vec2(x + w - rx, y), rx, ry, 0, false, true, Vec2(x + w, y + ry));
    path.lineTo(Vec2(x + w, y + h - ry));
    arcTo(path, Vec2(x + w, y + h - ry), rx, ry, 0, false, true, Vec2(x + w - rx, y + h));
    path.lineTo(Vec2(x + rx, y + h));
    arcTo(path, Vec2(x + rx, y + h), rx, ry, 0, false, true, Vec2(x, y + h - ry));
    path.lineTo(Vec2(x, y + ry));
    arcTo(path, Vec2(x, y + ry), rx, ry, 0, false, true, Vec2(x + rx, y));
    path.close();
}

/// Append an ellipse as four arcs, starting at `(cx + rx, cy)`.
void ellipsePath(ref Path path, double cx, double cy, double rx, double ry) pure nothrow @safe
{
    path.moveTo(Vec2(cx + rx, cy));
    arcTo(path, Vec2(cx + rx, cy), rx, ry, 0, false, true, Vec2(cx, cy + ry));
    arcTo(path, Vec2(cx, cy + ry), rx, ry, 0, false, true, Vec2(cx - rx, cy));
    arcTo(path, Vec2(cx - rx, cy), rx, ry, 0, false, true, Vec2(cx, cy - ry));
    arcTo(path, Vec2(cx, cy - ry), rx, ry, 0, false, true, Vec2(cx + rx, cy));
    path.close();
}
