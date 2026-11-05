// Package render walks a parsed SVG tree and paints it onto a canvas:
// property inheritance, transforms, use references, group opacity, shapes,
// fill and stroke.
package render

import (
	"errors"

	"svgraster/geom"
	"svgraster/raster"
	"svgraster/stroke"
	"svgraster/svgparse"
	"svgraster/svgpath"
	"svgraster/xmlmini"
)

// Tolerance is the flattening tolerance in device pixels.
const Tolerance = 0.01

// MaxUseDepth is the deepest use-expansion nesting that is still rendered.
const MaxUseDepth = 64

// Renderer renders documents. It reuses scratch memory between documents, so
// keep one around for many renders. It is not safe for concurrent use.
type Renderer struct {
	rast    *raster.Rasterizer
	stroker stroke.Stroker
	polys   geom.Polygons
	free    []*raster.Canvas // spare layers (always cleared)

	w, h int
	cur  *raster.Canvas
	ids  map[string]*xmlmini.Element
}

// New returns a Renderer.
func New() *Renderer { return &Renderer{} }

// Render draws the document with root element root onto a new w x h canvas.
func (r *Renderer) Render(root *xmlmini.Element, w, h int) (*raster.Canvas, error) {
	if root == nil || root.Tag != "svg" {
		return nil, errors.New("render: document element is not <svg>")
	}
	if w < 1 || h < 1 {
		return nil, errors.New("render: invalid image size")
	}
	if r.rast == nil {
		r.rast = raster.NewRasterizer(w)
	}
	if r.w != w || r.h != h {
		r.free = nil
	}
	r.w, r.h = w, h
	r.ids = map[string]*xmlmini.Element{}
	collectIDs(root, r.ids)
	canvas := raster.NewCanvas(w, h)
	r.cur = canvas

	vx, vy, vw, vh := viewport(root, w, h)
	sx, sy := float64(w)/vw, float64(h)/vh
	ctm0 := geom.Matrix{A: sx, D: sy, E: -vx * sx, F: -vy * sy}
	r.walk(root, ctm0, InitialStyle(), 0, true)
	return canvas, nil
}

func collectIDs(el *xmlmini.Element, ids map[string]*xmlmini.Element) {
	if id, ok := el.Attr("id"); ok {
		if _, dup := ids[id]; !dup {
			ids[id] = el
		}
	}
	for _, c := range el.Children {
		collectIDs(c, ids)
	}
}

// viewport determines the user-space rectangle that is stretched over the
// output (SPEC 7.1).
func viewport(root *xmlmini.Element, w, h int) (x, y, vw, vh float64) {
	if vb, ok := root.Attr("viewBox"); ok {
		if n := svgparse.NumberList(vb); len(n) >= 4 && n[2] > 0 && n[3] > 0 {
			return n[0], n[1], n[2], n[3]
		}
	}
	ws, okw := root.Attr("width")
	hs, okh := root.Attr("height")
	if okw && okh {
		wv, ok1 := svgparse.Length(ws)
		hv, ok2 := svgparse.Length(hs)
		if ok1 && ok2 && wv > 0 && hv > 0 {
			return 0, 0, wv, hv
		}
	}
	return 0, 0, float64(w), float64(h)
}

func (r *Renderer) walk(el *xmlmini.Element, parent geom.Matrix, ps Style, useDepth int, isRoot bool) {
	switch el.Tag {
	case "svg":
		if !isRoot {
			return
		}
	case "g", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
	default:
		return
	}
	d := collect(el)
	if d[pDisplay].set && d[pDisplay].val == "none" {
		return
	}
	opacity := 1.0
	if d[pOpacity].set {
		if v, ok := svgparse.Opacity(d[pOpacity].val); ok {
			opacity = v
		}
	}
	if opacity == 0 {
		return
	}
	style := d.apply(ps)
	ctm := parent
	if t, ok := el.Attr("transform"); ok {
		ctm = ctm.Mul(svgparse.Transform(t))
	}

	var saved *raster.Canvas
	if opacity < 1 {
		saved = r.cur
		r.cur = r.layer()
	}
	switch el.Tag {
	case "svg", "g":
		for _, c := range el.Children {
			r.walk(c, ctm, style, useDepth, false)
		}
	case "use":
		r.use(el, ctm, style, useDepth)
	default:
		if p := shapePath(el); p != nil {
			r.paint(p, ctm, &style, el.Tag != "line")
		}
	}
	if saved != nil {
		layer := r.cur
		r.cur = saved
		saved.CompositeLayer(layer, opacity)
		layer.Clear()
		r.free = append(r.free, layer)
	}
}

func (r *Renderer) layer() *raster.Canvas {
	if n := len(r.free); n > 0 {
		l := r.free[n-1]
		r.free = r.free[:n-1]
		return l
	}
	return raster.NewCanvas(r.w, r.h)
}

func (r *Renderer) use(el *xmlmini.Element, ctm geom.Matrix, style Style, depth int) {
	if depth >= MaxUseDepth {
		return
	}
	href, ok := el.Attr("href")
	if !ok || len(href) < 2 || href[0] != '#' {
		return
	}
	target := r.ids[href[1:]]
	if target == nil {
		return
	}
	x, y := attrLength(el, "x", 0), attrLength(el, "y", 0)
	r.walk(target, ctm.Mul(geom.Translate(x, y)), style, depth+1, false)
}

func attrLength(el *xmlmini.Element, name string, def float64) float64 {
	if s, ok := el.Attr(name); ok {
		if v, ok := svgparse.Length(s); ok {
			return v
		}
	}
	return def
}

// shapePath converts a shape element to a path in its user space, or nil if
// it draws nothing.
func shapePath(el *xmlmini.Element) *svgpath.Path {
	switch el.Tag {
	case "path":
		d, _ := el.Attr("d")
		return svgpath.ParseData(d)
	case "rect":
		x, y := attrLength(el, "x", 0), attrLength(el, "y", 0)
		w, h := attrLength(el, "width", 0), attrLength(el, "height", 0)
		if w <= 0 || h <= 0 {
			return nil
		}
		rx, okx := radius(el, "rx")
		ry, oky := radius(el, "ry")
		switch {
		case !okx && !oky:
			rx, ry = 0, 0
		case !okx:
			rx = ry
		case !oky:
			ry = rx
		}
		rx, ry = min(max(rx, 0), w/2), min(max(ry, 0), h/2)
		return svgpath.Rect(x, y, w, h, rx, ry)
	case "circle":
		rr := attrLength(el, "r", 0)
		if rr <= 0 {
			return nil
		}
		return svgpath.Ellipse(attrLength(el, "cx", 0), attrLength(el, "cy", 0), rr, rr)
	case "ellipse":
		rx, ry := attrLength(el, "rx", 0), attrLength(el, "ry", 0)
		if rx <= 0 || ry <= 0 {
			return nil
		}
		return svgpath.Ellipse(attrLength(el, "cx", 0), attrLength(el, "cy", 0), rx, ry)
	case "line":
		return svgpath.Line(attrLength(el, "x1", 0), attrLength(el, "y1", 0),
			attrLength(el, "x2", 0), attrLength(el, "y2", 0))
	case "polyline", "polygon":
		pts, _ := el.Attr("points")
		return svgpath.Poly(svgparse.NumberList(pts), el.Tag == "polygon")
	}
	return nil
}

// radius reads a rect corner radius; ok is false when absent or "auto".
func radius(el *xmlmini.Element, name string) (float64, bool) {
	s, ok := el.Attr(name)
	if !ok {
		return 0, false
	}
	return svgparse.Length(s)
}

func (r *Renderer) colour(p svgparse.Paint, s *Style) (cr, cg, cb float64) {
	c := p.RGB
	if p.Kind == svgparse.PaintCurrent {
		c = s.Color
	}
	return float64(c.R) / 255, float64(c.G) / 255, float64(c.B) / 255
}

// paint fills (if fillable) and then strokes the path p under the CTM.
func (r *Renderer) paint(p *svgpath.Path, ctm geom.Matrix, s *Style, fillable bool) {
	if fillable && s.Fill.Kind != svgparse.PaintNone && s.FillOpacity > 0 {
		r.polys.Reset()
		for _, sub := range svgpath.Flatten(p, ctm, Tolerance) {
			if len(sub.Pts) < 3 {
				continue
			}
			for _, pt := range sub.Pts {
				r.polys.Add(pt)
			}
			r.polys.End()
		}
		cr, cg, cb := r.colour(s.Fill, s)
		r.rast.Fill(r.cur, &r.polys, s.FillRule, cr, cg, cb, s.FillOpacity)
	}
	if s.Stroke.Kind == svgparse.PaintNone || !(s.StrokeWidth > 0) || s.StrokeOpacity <= 0 {
		return
	}
	scale := ctm.MaxScale()
	if !(scale > 0) {
		return
	}
	tol := Tolerance / scale
	subs := svgpath.Flatten(p, geom.Identity, tol)
	r.polys.Reset()
	r.stroker.Outline(&r.polys, subs, stroke.Options{
		Width: s.StrokeWidth, Cap: s.Cap, Join: s.Join, MiterLimit: s.MiterLimit, Tol: tol,
	})
	r.polys.Transform(ctm)
	cr, cg, cb := r.colour(s.Stroke, s)
	r.rast.Fill(r.cur, &r.polys, raster.NonZero, cr, cg, cb, s.StrokeOpacity)
}
