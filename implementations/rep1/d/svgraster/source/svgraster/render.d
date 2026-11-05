/// The document walk: viewport, property inheritance, `use`, group opacity
/// and painting of shapes.
module svgraster.render;

import std.math : isFinite;
import svgraster.buf;
import svgraster.geom;
import svgraster.parse;
import svgraster.path;
import svgraster.raster;
import svgraster.shapes;
import svgraster.stroke;
import svgraster.xml;

/// A rendered 8-bit RGB image.
struct Image
{
    /// Width in pixels.
    int width;
    /// Height in pixels.
    int height;
    /// `width * height * 3` bytes, rows top to bottom.
    ubyte[] rgb;

    /// The binary PPM ("P6") encoding of the image.
    ubyte[] toPpm() const pure nothrow @safe
    {
        import std.conv : to;

        immutable header = "P6\n" ~ width.to!string ~ " " ~ height.to!string ~ "\n255\n";
        auto o = new ubyte[](header.length + rgb.length);
        foreach (i, c; header)
            o[i] = cast(ubyte) c;
        o[header.length .. $] = rgb[];
        return o;
    }
}

/// Maximum element nesting (including `use` expansion) that is rendered.
enum maxDepth = 64;

private enum double flattenTolerance = 0.01;

/// Computed, typed values of the inherited painting properties.
struct Props
{
    Paint fill = Paint(PaintKind.color, 0, 0, 0);
    Paint stroke;
    double fillOpacity = 1;
    double strokeOpacity = 1;
    double strokeWidth = 1;
    double miterLimit = 4;
    FillRule fillRule = FillRule.nonzero;
    LineCap lineCap = LineCap.butt;
    LineJoin lineJoin = LineJoin.miter;
    Paint color = Paint(PaintKind.color, 0, 0, 0);
}

/// Renders parsed documents. A renderer owns scratch memory that is reused
/// between calls, so create one and render many documents with it.
final class Renderer
{
    private int w, h;
    private Rasterizer rast;
    private Canvas root;
    private Canvas[] layerPool;
    private Canvas target;
    private Document doc;

    private Path path;
    private FlatPath flat;
    private Outline outline;
    private Buf!Vec2 strokeScratch;
    private Buf!Decl decls;

    /// Render `document` at `width` x `height` pixels.
    Image render(Document document, int width, int height)
    {
        if (width != w || height != h || rast is null)
        {
            w = width;
            h = height;
            rast = new Rasterizer(w, h);
            root = new Canvas(w, h);
            layerPool = null;
        }
        else
            root.clear();
        doc = document;
        target = root;
        if (doc.root !is null && doc.root.tag == "svg")
        {
            immutable ctm0 = viewportTransform(doc.root, w, h);
            renderElement(doc.root, ctm0, Props.init, 0, true);
        }
        Image img;
        img.width = w;
        img.height = h;
        img.rgb = root.toRgb8();
        doc = Document.init;
        return img;
    }

    private Canvas acquireLayer()
    {
        if (layerPool.length)
        {
            auto l = layerPool[$ - 1];
            layerPool = layerPool[0 .. $ - 1];
            return l;
        }
        return new Canvas(w, h);
    }

    private void releaseLayer(Canvas l)
    {
        l.clear();
        layerPool ~= l;
    }

    // ---- property lookup --------------------------------------------------

    /// Value of property `name` for the element whose style is in `decls`:
    /// the style declaration if present, else the attribute, else null.
    private const(char)[] lookup(const Element e, string name)
    {
        foreach_reverse (ref d; decls.slice)
            if (equalsIgnoreCase(d.name, name))
                return d.value;
        if (e.has(name))
            return e.attr(name);
        return null;
    }

    private void loadStyle(const Element e)
    {
        decls.clear();
        if (e.has("style"))
            parseStyle(e.attr("style"), decls);
    }

    private Props computeProps(const Element e, Props p)
    {
        if (auto v = lookup(e, "color"))
        {
            Paint c;
            if (!parsePaint(v, c) || c.kind == PaintKind.none)
                p.color = Paint(PaintKind.color, 0, 0, 0);
            else if (c.kind == PaintKind.color)
                p.color = c;
            // `currentColor` as a colour keeps the inherited value.
        }
        if (auto v = lookup(e, "fill"))
        {
            Paint c;
            p.fill = parsePaint(v, c) ? c : Paint(PaintKind.color, 0, 0, 0);
        }
        if (auto v = lookup(e, "stroke"))
        {
            Paint c;
            p.stroke = parsePaint(v, c) ? c : Paint.none;
        }
        if (auto v = lookup(e, "fill-opacity"))
        {
            double o;
            p.fillOpacity = parseOpacity(v, o) ? o : 1;
        }
        if (auto v = lookup(e, "stroke-opacity"))
        {
            double o;
            p.strokeOpacity = parseOpacity(v, o) ? o : 1;
        }
        if (auto v = lookup(e, "stroke-width"))
        {
            double o;
            p.strokeWidth = parseLength(v, o) ? o : 1;
        }
        if (auto v = lookup(e, "stroke-miterlimit"))
        {
            double o;
            p.miterLimit = parseLength(v, o) ? o : 4;
        }
        if (auto v = lookup(e, "fill-rule"))
        {
            auto t = trim(v);
            p.fillRule = t == "evenodd" ? FillRule.evenodd : FillRule.nonzero;
        }
        if (auto v = lookup(e, "stroke-linecap"))
        {
            auto t = trim(v);
            p.lineCap = t == "round" ? LineCap.round : (t == "square" ? LineCap.square : LineCap.butt);
        }
        if (auto v = lookup(e, "stroke-linejoin"))
        {
            auto t = trim(v);
            p.lineJoin = t == "round" ? LineJoin.round : (t == "bevel" ? LineJoin.bevel : LineJoin.miter);
        }
        return p;
    }

    // ---- the walk ---------------------------------------------------------

    private void renderChildren(Element e, const Matrix ctm, const Props props, int depth)
    {
        foreach (c; e.children)
            renderElement(c, ctm, props, depth + 1, false);
    }

    private void renderElement(Element e, const Matrix parentCtm, const Props parentProps, int depth, bool isRoot)
    {
        if (depth > maxDepth)
            return;
        immutable tag = e.tag;
        immutable isShape = isShapeTag(tag);
        if (!(isRoot || isShape || tag == "g" || tag == "use"))
            return;

        loadStyle(e);
        if (auto dv = lookup(e, "display"))
            if (trim(dv) == "none")
                return;
        double opacity = 1;
        if (auto ov = lookup(e, "opacity"))
            if (!parseOpacity(ov, opacity))
                opacity = 1;
        if (opacity <= 0)
            return;
        Props props = computeProps(e, parentProps);

        Matrix ctm = parentCtm;
        if (e.has("transform"))
            ctm = ctm * parseTransform(e.attr("transform"));

        Canvas saved = target;
        Canvas layer = null;
        if (opacity < 1)
        {
            layer = acquireLayer();
            target = layer;
        }

        if (isShape)
            paintShape(e, ctm, props);
        else if (tag == "use")
            renderUse(e, ctm, props, depth);
        else
            renderChildren(e, ctm, props, depth);

        if (layer !is null)
        {
            target = saved;
            saved.compositeLayer(layer, opacity);
            releaseLayer(layer);
        }
    }

    private void renderUse(Element e, const Matrix ctm, const Props props, int depth)
    {
        auto href = trim(e.attr("href"));
        if (href.length < 2 || href[0] != '#')
            return;
        auto ref_ = doc.byId(cast(string) href[1 .. $]);
        if (ref_ is null)
            return;
        immutable tag = ref_.tag;
        if (!(tag == "g" || isShapeTag(tag)))
            return;
        double x = 0, y = 0;
        if (e.has("x"))
            parseLength(e.attr("x"), x);
        if (e.has("y"))
            parseLength(e.attr("y"), y);
        renderElement(ref_, ctm * Matrix.translate(x, y), props, depth + 1, false);
    }

    private static Paint resolve(Paint p, Paint color)
    {
        return p.kind == PaintKind.currentColor ? color : p;
    }

    private void paintShape(Element e, const Matrix ctm, const Props props)
    {
        path.clear();
        if (!shapeToPath(e, path))
            return;

        immutable fill = resolve(props.fill, props.color);
        if (fill.kind == PaintKind.color && props.fillOpacity > 0 && e.tag != "line")
        {
            flatten(path, ctm, flattenTolerance, flat);
            rast.begin();
            foreach (sub; flat.subs.slice)
                rast.addPolygon(flat.points(sub));
            rast.fill(target, props.fillRule, fill.r, fill.g, fill.b, props.fillOpacity);
        }

        immutable stroke = resolve(props.stroke, props.color);
        if (stroke.kind == PaintKind.color && props.strokeWidth > 0 && props.strokeOpacity > 0)
        {
            immutable s = ctm.maxScale();
            if (s > 0 && isFinite(s))
            {
                immutable tol = flattenTolerance / s;
                flatten(path, Matrix.init, tol, flat);
                StrokeStyle st;
                st.width = props.strokeWidth;
                st.cap = props.lineCap;
                st.join = props.lineJoin;
                st.miterLimit = props.miterLimit;
                buildStroke(flat, st, tol, outline, strokeScratch);
                outline.transform(ctm);
                rast.begin();
                foreach (i; 0 .. outline.pieces)
                    rast.addPolygon(outline.piece(i));
                rast.fill(target, FillRule.nonzero, stroke.r, stroke.g, stroke.b, props.strokeOpacity);
            }
        }
    }
}

/// The initial transform mapping user space to device space (SPEC §7.1).
Matrix viewportTransform(const Element svg, int w, int h)
{
    double vx = 0, vy = 0, vw = w, vh = h;
    bool done = false;
    if (svg.has("viewBox"))
    {
        Buf!double nums;
        parseNumberList(svg.attr("viewBox"), nums);
        if (nums.length >= 4 && nums[2] > 0 && nums[3] > 0)
        {
            vx = nums[0];
            vy = nums[1];
            vw = nums[2];
            vh = nums[3];
            done = true;
        }
    }
    if (!done)
    {
        double sw, sh;
        if (svg.has("width") && svg.has("height") && parseLength(svg.attr("width"), sw)
            && parseLength(svg.attr("height"), sh) && sw > 0 && sh > 0)
        {
            vw = sw;
            vh = sh;
        }
    }
    immutable sx = w / vw, sy = h / vh;
    return Matrix(sx, 0, 0, sy, -vx * sx, -vy * sy);
}

/// Parse `svg` and render it at `width` x `height`.
Image renderSvg(string svg, int width, int height)
{
    auto r = new Renderer;
    return r.render(parseXml(svg), width, height);
}
