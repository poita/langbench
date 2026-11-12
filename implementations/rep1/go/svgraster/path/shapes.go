package path

import (
	"svgraster/geom"
)

// Rect returns the path of a rectangle with optional rounded corners, or nil
// if w or h is not positive. rx and ry must already be resolved (non-negative,
// at most half the width and height respectively).
func Rect(x, y, w, h, rx, ry float64) *Path {
	if !(w > 0) || !(h > 0) {
		return nil
	}
	p := &Path{}
	if rx <= 0 || ry <= 0 {
		p.MoveTo(geom.Point{X: x, Y: y})
		p.LineTo(geom.Point{X: x + w, Y: y})
		p.LineTo(geom.Point{X: x + w, Y: y + h})
		p.LineTo(geom.Point{X: x, Y: y + h})
		p.Close()
		return p
	}
	pt := func(a, b float64) geom.Point { return geom.Point{X: a, Y: b} }
	p.MoveTo(pt(x+rx, y))
	p.LineTo(pt(x+w-rx, y))
	p.ArcTo(pt(x+w-rx, y), rx, ry, 0, false, true, pt(x+w, y+ry))
	p.LineTo(pt(x+w, y+h-ry))
	p.ArcTo(pt(x+w, y+h-ry), rx, ry, 0, false, true, pt(x+w-rx, y+h))
	p.LineTo(pt(x+rx, y+h))
	p.ArcTo(pt(x+rx, y+h), rx, ry, 0, false, true, pt(x, y+h-ry))
	p.LineTo(pt(x, y+ry))
	p.ArcTo(pt(x, y+ry), rx, ry, 0, false, true, pt(x+rx, y))
	p.Close()
	return p
}

// Ellipse returns the path of an ellipse, or nil if either radius is not
// positive.
func Ellipse(cx, cy, rx, ry float64) *Path {
	if !(rx > 0) || !(ry > 0) {
		return nil
	}
	p := &Path{}
	pt := func(a, b float64) geom.Point { return geom.Point{X: a, Y: b} }
	p.MoveTo(pt(cx+rx, cy))
	p.ArcTo(pt(cx+rx, cy), rx, ry, 0, false, true, pt(cx, cy+ry))
	p.ArcTo(pt(cx, cy+ry), rx, ry, 0, false, true, pt(cx-rx, cy))
	p.ArcTo(pt(cx-rx, cy), rx, ry, 0, false, true, pt(cx, cy-ry))
	p.ArcTo(pt(cx, cy-ry), rx, ry, 0, false, true, pt(cx+rx, cy))
	p.Close()
	return p
}

// Line returns the path of a single line segment.
func Line(x1, y1, x2, y2 float64) *Path {
	p := &Path{}
	p.MoveTo(geom.Point{X: x1, Y: y1})
	p.LineTo(geom.Point{X: x2, Y: y2})
	return p
}

// Poly returns the path through the given coordinate list (x0 y0 x1 y1 ...),
// closed for a polygon. An odd trailing number is discarded; nil is returned
// if there are no points.
func Poly(coords []float64, closed bool) *Path {
	n := len(coords) / 2
	if n == 0 {
		return nil
	}
	p := &Path{}
	for i := 0; i < n; i++ {
		pt := geom.Point{X: coords[2*i], Y: coords[2*i+1]}
		if i == 0 {
			p.MoveTo(pt)
		} else {
			p.LineTo(pt)
		}
	}
	if closed {
		p.Close()
	}
	return p
}
