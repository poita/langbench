/// The document renderer: viewport setup, property inheritance, transforms,
/// `use` expansion, group opacity and painting.
module svgraster.render;

import svgraster.colors;
import svgraster.geom;
import svgraster.parse;
import svgraster.path;
import svgraster.raster;
import svgraster.shapes;
import svgraster.stroke;
import svgraster.xml;

/// Flattening tolerance in device pixels.
private enum deviceTolerance = 0.01;
/// Maximum element nesting depth (counting `use` expansion).
private enum maxDepth = 64;

/// A `fill`/`stroke` value, kept symbolic so `currentColor` resolves against
/// the colour of the element that is painted.
private struct PaintSpec
{
    bool none;
    bool current;
    Rgb rgb;
}

/// The computed inherited painting properties of an element.
private struct Props
{
    PaintSpec fill = PaintSpec(false, false, Rgb(0, 0, 0));
    double fillOpacity = 1;
    FillRule fillRule = FillRule.nonzero;
    PaintSpec stroke = PaintSpec(true);
    double strokeWidth = 1;
    LineCap lineCap = LineCap.butt;
    LineJoin lineJoin = LineJoin.miter;
    double miterLimit = 4;
    double strokeOpacity = 1;
    Rgb color = Rgb(0, 0, 0);
}

/// Render the SVG document `src` onto a new `width` x `height` canvas.
///
/// Throws: `XmlException` if `src` has no document element.
Canvas renderSvg(const(char)[] src, int width, int height)
{
    auto root = parseXml(src);
    auto canvas = new Canvas(width, height);
    if (root.tag != "svg")
        return canvas;
    auto r = Renderer(width, height);
    r.indexIds(root);
    r.render(root, viewportTransform(root, width, height), Props.init, canvas, 0);
    return canvas;
}

/// The transform from the document's user space to a `width` x `height`
/// output (SPEC.md §7.1). The view box is stretched to fill the output.
Matrix viewportTransform(const Element root, int width, int height)
{
    double vx = 0, vy = 0, vw = width, vh = height;
    const vb = parseNumberList(root.get("viewBox"));
    double w, h;
    if (vb.length >= 4 && vb[2] > 0 && vb[3] > 0)
    {
        vx = vb[0];
        vy = vb[1];
        vw = vb[2];
        vh = vb[3];
    }
    else if (parseLength(root.get("width"), w) && parseLength(root.get("height"), h)
            && w > 0 && h > 0)
    {
        vw = w;
        vh = h;
    }
    immutable sx = width / vw, sy = height / vh;
    return Matrix(sx, 0, 0, sy, -vx * sx, -vy * sy);
}

private struct Renderer
{
    int width, height;
    Element[string] ids;
    Rasterizer rasterizer;

    this(int w, int h)
    {
        width = w;
        height = h;
    }

    void indexIds(Element el)
    {
        if (auto id = el.get("id"))
        {
            if (id !in ids)
                ids[id] = el;
        }
        foreach (c; el.children)
            indexIds(c);
    }

    void render(const Element el, Matrix parentCtm, const Props inherited, Canvas canvas, int depth)
    {
        if (depth > maxDepth)
            return;
        immutable isRoot = el.parent is null;
        if (!isRoot && el.tag != "g" && el.tag != "use" && !isShape(el.tag))
            return;
        if (isRoot && el.tag != "svg")
            return;

        string[string] style;
        if (auto st = el.get("style"))
            style = parseStyle(st);
        string prop(string name)
        {
            if (auto v = name in style)
                return *v;
            immutable a = el.get(name);
            return a.length ? a : null;
        }

        if (prop("display") == "none")
            return;
        double opacity = 1;
        if (auto o = prop("opacity"))
            if (!parseOpacity(o, opacity))
                opacity = 1;
        if (opacity <= 0)
            return;

        immutable ctm = parentCtm * parseTransform(el.get("transform"));
        immutable props = computeProps(inherited, &prop);

        if (opacity < 1)
        {
            auto layer = new Canvas(width, height);
            renderBody(el, ctm, props, layer, depth);
            canvas.compositeLayer(layer, opacity);
        }
        else
            renderBody(el, ctm, props, canvas, depth);
    }

    private void renderBody(const Element el, Matrix ctm, const Props props, Canvas canvas, int depth)
    {
        switch (el.tag)
        {
        case "svg", "g":
            foreach (c; el.children)
                render(c, ctm, props, canvas, depth + 1);
            break;
        case "use":
            {
                immutable href = el.get("href");
                if (href.length < 2 || href[0] != '#')
                    break;
                auto target = href[1 .. $] in ids;
                if (target is null || !((*target).tag == "g" || isShape((*target).tag)))
                    break;
                immutable m = ctm * Matrix.translation(lengthOr(el.get("x"), 0),
                        lengthOr(el.get("y"), 0));
                render(*target, m, props, canvas, depth + 1);
            }
            break;
        default:
            paintShape(el, ctm, props, canvas);
        }
    }

    private void paintShape(const Element el, Matrix ctm, const Props props, Canvas canvas)
    {
        const path = shapeToPath(el);
        if (path.segments.length == 0)
            return;

        if (!props.fill.none && props.fillOpacity > 0)
        {
            immutable c = resolve(props.fill, props.color);
            const polys = flatten(path.transformed(ctm), deviceTolerance);
            const(Point[])[] rings;
            foreach (ref pl; polys)
                rings ~= pl.points;
            rasterizer.fill(canvas, rings, props.fillRule,
                    Paint(c.r / 255.0, c.g / 255.0, c.b / 255.0, props.fillOpacity));
        }

        if (!props.stroke.none && props.strokeWidth > 0 && props.strokeOpacity > 0)
        {
            immutable scale = ctm.maxScale;
            if (!(scale > 0))
                return;
            immutable tol = deviceTolerance / scale;
            immutable c = resolve(props.stroke, props.color);
            const polys = flatten(path, tol);
            auto outline = strokeOutline(polys,
                    StrokeStyle(props.strokeWidth, props.lineCap, props.lineJoin, props.miterLimit), tol);
            foreach (ref poly; outline)
                foreach (ref pt; poly)
                    pt = ctm.apply(pt);
            const(Point[])[] rings = outline;
            rasterizer.fill(canvas, rings, FillRule.nonzero,
                    Paint(c.r / 255.0, c.g / 255.0, c.b / 255.0, props.strokeOpacity));
        }
    }
}

private Rgb resolve(const PaintSpec p, Rgb color)
{
    return p.current ? color : p.rgb;
}

/// Compute the inherited painting properties of an element from its parent's
/// and the element's own `style`/attribute values (`prop` returns the raw
/// value or `null`).
private Props computeProps(const Props parent, scope string delegate(string) prop)
{
    Props p = parent;

    if (auto v = prop("color"))
    {
        ParsedColor pc;
        if (parseColor(v, pc) && !pc.none)
            p.color = pc.current ? parent.color : pc.rgb;
    }
    p.fill = paintProp(prop("fill"), p.fill);
    p.stroke = paintProp(prop("stroke"), p.stroke);
    p.fillOpacity = opacityProp(prop("fill-opacity"), p.fillOpacity);
    p.strokeOpacity = opacityProp(prop("stroke-opacity"), p.strokeOpacity);
    if (auto v = prop("fill-rule"))
        p.fillRule = v == "evenodd" ? FillRule.evenodd : FillRule.nonzero;
    if (auto v = prop("stroke-linecap"))
        p.lineCap = v == "round" ? LineCap.round : (v == "square" ? LineCap.square : LineCap.butt);
    if (auto v = prop("stroke-linejoin"))
        p.lineJoin = v == "round" ? LineJoin.round : (v == "bevel" ? LineJoin.bevel : LineJoin.miter);
    if (auto v = prop("stroke-width"))
    {
        double w;
        if (parseLength(v, w))
            p.strokeWidth = w;
    }
    if (auto v = prop("stroke-miterlimit"))
    {
        double w;
        if (parseLength(v, w))
            p.miterLimit = w;
    }
    return p;
}

private PaintSpec paintProp(string v, PaintSpec inherited)
{
    if (v is null)
        return inherited;
    ParsedColor pc;
    if (!parseColor(v, pc))
        return inherited;
    return PaintSpec(pc.none, pc.current, pc.rgb);
}

private double opacityProp(string v, double inherited)
{
    if (v is null)
        return inherited;
    double o = 1;
    if (!parseOpacity(v, o))
        return 1;
    return o;
}

unittest
{
    import std.conv : to;

    // The rectangle of SPEC.md §10.1.
    auto c = renderSvg(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 4" width="8" height="4">
        <rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/></svg>`, 8, 4);
    const ppm = c.toPpm();
    immutable hdr = "P6\n8 4\n255\n".length;
    assert(ppm[hdr + (8 + 4) * 3 .. hdr + (8 + 5) * 3] == [128, 128, 255]);
}

unittest
{
    // Group opacity composites the group as one object (SPEC.md §10.4).
    auto grp = renderSvg(`<svg viewBox="0 0 4 1"><g opacity="0.5">
        <rect width="2" height="1" fill="red"/><rect width="2" height="1" fill="blue"/></g></svg>`, 4, 1);
    immutable hdr = "P6\n4 1\n255\n".length;
    auto p = grp.toPpm();
    assert(p[hdr .. hdr + 3] == [128, 128, 255]);
    auto each = renderSvg(`<svg viewBox="0 0 4 1">
        <rect width="2" height="1" fill="red" opacity="0.5"/>
        <rect width="2" height="1" fill="blue" opacity="0.5"/></svg>`, 4, 1);
    assert(each.toPpm()[hdr .. hdr + 3] != [128, 128, 255]);
}

unittest
{
    // use: inherits from the use element, honours translate and its own transform.
    auto c = renderSvg(`<svg viewBox="0 0 4 1"><defs><rect id="r" width="1" height="1"/></defs>
        <use href="#r" x="2" fill="lime"/><use href="#missing"/></svg>`, 4, 1);
    immutable hdr = "P6\n4 1\n255\n".length;
    auto p = c.toPpm();
    assert(p[hdr .. hdr + 3] == [255, 255, 255]);
    assert(p[hdr + 6 .. hdr + 9] == [0, 255, 0]);
}

unittest
{
    // display precedence: style beats the attribute, and hides the subtree.
    auto c = renderSvg(`<svg viewBox="0 0 2 1">
        <g display="none" style="display:inline"><rect width="1" height="1"/></g>
        <g style="display:none"><rect x="1" width="1" height="1"/></g></svg>`, 2, 1);
    immutable hdr = "P6\n2 1\n255\n".length;
    auto p = c.toPpm();
    assert(p[hdr .. hdr + 3] == [0, 0, 0]);
    assert(p[hdr + 3 .. hdr + 6] == [255, 255, 255]);
}

unittest
{
    // currentColor and stroke geometry: a 1-wide stroke around a 2x2 square.
    auto c = renderSvg(`<svg viewBox="0 0 4 4" color="#ff0000">
        <rect x="1" y="1" width="2" height="2" fill="none" stroke="currentColor"/></svg>`, 4, 4);
    immutable hdr = "P6\n4 4\n255\n".length;
    auto p = c.toPpm();
    // Pixel (0,0) is covered by a quarter of the miter corner.
    assert(p[hdr + 1 .. hdr + 3] == [191, 191]);
    // The stroke straddles the rectangle edge: the pixel (1,1) is half covered.
    assert(p[hdr + (4 + 1) * 3] == 255);
}
