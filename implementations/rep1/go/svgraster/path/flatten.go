package path

import (
	"math"

	"svgraster/geom"
)

// DefaultTolerance is the flattening tolerance, in device pixels.
const DefaultTolerance = 0.01

// maxSteps caps the number of line segments a single cubic is split into.
const maxSteps = 1000

// Subpath is a flattened subpath.
type Subpath struct {
	// Points are the vertices of the polyline.
	Points []geom.Point
	// Closed reports whether the subpath ended with a Close segment.
	Closed bool
}

// Flatten converts p to polylines. Every point is first transformed by m, and
// curves are subdivided so that the polyline stays within tol of the true
// curve measured in the transformed space.
//
// A subpath is started by MoveTo; a MoveTo that is not followed by a drawing
// segment or Close produces no subpath. After a Close, a drawing segment
// starts a new subpath at the start point of the closed one.
func (p *Path) Flatten(m geom.Matrix, tol float64) []Subpath {
	var out []Subpath
	var start geom.Point
	idx := -1            // index in out of the open subpath, or -1
	pendingMove := false // a MoveTo not yet followed by a drawing segment

	open := func() *Subpath {
		if idx < 0 {
			out = append(out, Subpath{Points: []geom.Point{m.Apply(start)}})
			idx = len(out) - 1
		}
		pendingMove = false
		return &out[idx]
	}
	for _, s := range p.Segs {
		switch s.Kind {
		case MoveTo:
			start = s.P[0]
			pendingMove = true
			idx = -1
		case LineTo:
			sp := open()
			sp.Points = append(sp.Points, m.Apply(s.P[0]))
		case CubicTo:
			sp := open()
			last := sp.Points[len(sp.Points)-1]
			sp.Points = appendCubic(sp.Points, last, m.Apply(s.P[0]), m.Apply(s.P[1]), m.Apply(s.P[2]), tol)
		case Close:
			if idx < 0 && !pendingMove {
				continue // nothing to close
			}
			open().Closed = true
			idx = -1
		}
	}
	return out
}

// appendCubic appends the flattening of the cubic p0..p3 (excluding p0).
func appendCubic(pts []geom.Point, p0, p1, p2, p3 geom.Point, tol float64) []geom.Point {
	d1 := p0.Sub(p1.Scale(2)).Add(p2)
	d2 := p1.Sub(p2.Scale(2)).Add(p3)
	m := math.Max(d1.Dot(d1), d2.Dot(d2))
	nf := math.Ceil(math.Sqrt(0.75 * math.Sqrt(m) / tol))
	n := maxSteps
	if nf < maxSteps { // also false for NaN
		n = int(nf)
	}
	if n < 1 {
		n = 1
	}
	for i := 1; i < n; i++ {
		t := float64(i) / float64(n)
		u := 1 - t
		a, b, c, d := u*u*u, 3*u*u*t, 3*u*t*t, t*t*t
		pts = append(pts, geom.Point{
			X: a*p0.X + b*p1.X + c*p2.X + d*p3.X,
			Y: a*p0.Y + b*p1.Y + c*p2.Y + d*p3.Y,
		})
	}
	return append(pts, p3)
}
