// Package render walks an SVG element tree and paints it onto a canvas:
// property inheritance, transforms, <use> expansion, fills, strokes and group
// opacity.
package render

import (
	"math"

	"svgraster/geom"
	"svgraster/path"
	"svgraster/raster"
	"svgraster/stroke"
	"svgraster/svgparse"
	"svgraster/xmlmini"
)

// maxDepth is the deepest nesting (including <use> expansion) that is drawn.
const maxDepth = 64

// Render draws the document rooted at root (an <svg> element) onto a new
// width x height canvas and returns it.
func Render(root *xmlmini.Node, width, height int) *raster.Canvas {
	r := &renderer{
		ids:    map[string]*xmlmini.Node{},
		canvas: raster.NewCanvas(width, height),
		w:      width,
		h:      height,
	}
	r.collectIDs(root)
	if root.Tag == "svg" {
		r.node(root, ViewportMatrix(root, width, height), initialStyle(), 0, true)
	}
	return r.canvas
}

// ViewportMatrix returns the transform from the root element's user space to
// a width x height pixel grid (SPEC §7.1): the view box is stretched to fill
// the output.
func ViewportMatrix(root *xmlmini.Node, width, height int) geom.Matrix {
	vx, vy := 0.0, 0.0
	vw, vh := float64(width), float64(height)
	if s, ok := root.Attr("viewBox"); ok {
		if x, y, w, h, ok := svgparse.ViewBox(s); ok {
			vx, vy, vw, vh = x, y, w, h
			return viewport(vx, vy, vw, vh, width, height)
		}
	}
	w, wok := lengthAttr(root, "width")
	h, hok := lengthAttr(root, "height")
	if wok && hok && w > 0 && h > 0 {
		vw, vh = w, h
	}
	return viewport(vx, vy, vw, vh, width, height)
}

func viewport(vx, vy, vw, vh float64, width, height int) geom.Matrix {
	sx, sy := float64(width)/vw, float64(height)/vh
	return geom.Matrix{A: sx, D: sy, E: -vx * sx, F: -vy * sy}
}

type renderer struct {
	ids    map[string]*xmlmini.Node
	canvas *raster.Canvas // current drawing target
	pool   []*raster.Canvas
	w, h   int
}

func (r *renderer) collectIDs(n *xmlmini.Node) {
	if id, ok := n.Attr("id"); ok {
		if _, dup := r.ids[id]; !dup {
			r.ids[id] = n
		}
	}
	for _, c := range n.Children {
		r.collectIDs(c)
	}
}

func lengthAttr(n *xmlmini.Node, name string) (float64, bool) {
	if s, ok := n.Attr(name); ok {
		return svgparse.ParseLength(s)
	}
	return 0, false
}

func lengthOr(n *xmlmini.Node, name string, def float64) float64 {
	if v, ok := lengthAttr(n, name); ok {
		return v
	}
	return def
}

func (r *renderer) layer() *raster.Canvas {
	if k := len(r.pool); k > 0 {
		c := r.pool[k-1]
		r.pool = r.pool[:k-1]
		return c
	}
	return raster.NewCanvas(r.w, r.h)
}

// node renders one element and its subtree. ctm is the matrix of the parent
// (for the document element, the viewport transform).
func (r *renderer) node(n *xmlmini.Node, ctm geom.Matrix, parent style, depth int, isRoot bool) {
	if depth > maxDepth {
		return
	}
	switch n.Tag {
	case "svg":
		if !isRoot {
			return
		}
	case "g", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
	default:
		return
	}
	p := newProps(n)
	if hidden(p) {
		return
	}
	op := opacityOf(p)
	if op == 0 {
		return
	}
	if !isRoot {
		if t, ok := n.Attr("transform"); ok {
			ctm = ctm.Mul(svgparse.ParseTransform(t))
		}
	}
	st := computeStyle(parent, p)

	target := r.canvas
	var layer *raster.Canvas
	if op < 1 {
		layer = r.layer()
		r.canvas = layer
	}

	switch n.Tag {
	case "svg", "g":
		for _, c := range n.Children {
			r.node(c, ctm, st, depth+1, false)
		}
	case "use":
		r.use(n, ctm, st, depth)
	default:
		r.shape(n, ctm, st)
	}

	if layer != nil {
		r.canvas = target
		target.DrawLayer(layer, op)
		layer.Clear()
		r.pool = append(r.pool, layer)
	}
}

func (r *renderer) use(n *xmlmini.Node, ctm geom.Matrix, st style, depth int) {
	href, ok := n.Attr("href")
	if !ok || len(href) < 2 || href[0] != '#' {
		return
	}
	target, ok := r.ids[href[1:]]
	if !ok {
		return
	}
	m := ctm.Mul(geom.Translate(lengthOr(n, "x", 0), lengthOr(n, "y", 0)))
	r.node(target, m, st, depth+1, false)
}

// shape paints a basic shape or path element.
func (r *renderer) shape(n *xmlmini.Node, ctm geom.Matrix, st style) {
	pth := ShapePath(n)
	if pth == nil || len(pth.Segs) == 0 {
		return
	}
	r.fill(pth, ctm, st)
	r.stroke(pth, ctm, st)
}

func (r *renderer) fill(pth *path.Path, ctm geom.Matrix, st style) {
	rgb, ok := st.resolve(st.fill)
	if !ok || st.fillOpacity == 0 {
		return
	}
	var polys [][]geom.Point
	for _, sp := range pth.Flatten(ctm, path.DefaultTolerance) {
		if len(sp.Points) >= 3 {
			polys = append(polys, sp.Points)
		}
	}
	r.canvas.FillPolygons(polys, st.fillRule, rgb, st.fillOpacity)
}

func (r *renderer) stroke(pth *path.Path, ctm geom.Matrix, st style) {
	rgb, ok := st.resolve(st.stroke)
	if !ok || !(st.strokeWidth > 0) || st.strokeOpacity == 0 {
		return
	}
	scale := ctm.MaxScale()
	if !(scale > 0) || math.IsInf(scale, 0) {
		return
	}
	tol := path.DefaultTolerance / scale
	subs := pth.Flatten(geom.Identity, tol)
	polys := stroke.Outline(subs, stroke.Style{
		Width: st.strokeWidth, Cap: st.cap, Join: st.join, MiterLimit: st.miterLimit,
	}, tol)
	for _, poly := range polys {
		for i, pt := range poly {
			poly[i] = ctm.Apply(pt)
		}
	}
	r.canvas.FillPolygons(raster.Orient(polys), raster.NonZero, rgb, st.strokeOpacity)
}
