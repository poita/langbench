// Package stroke turns flattened centrelines into stroke outlines. The
// outline is not a single polygon but a bag of convex pieces — one rectangle
// per segment, one piece per join, one per cap — every one oriented with
// positive signed area. Filling them together with the nonzero rule yields
// their union.
package stroke

import (
	"math"

	"svgraster/geom"
	"svgraster/svgpath"
)

// Cap is a line cap style.
type Cap uint8

// Line caps.
const (
	CapButt Cap = iota
	CapRound
	CapSquare
)

// Join is a line join style.
type Join uint8

// Line joins.
const (
	JoinMiter Join = iota
	JoinRound
	JoinBevel
)

// Options describes a stroke.
type Options struct {
	Width      float64
	Cap        Cap
	Join       Join
	MiterLimit float64 // values below 1 are treated as 1
	// Tol is the maximum distance, in the coordinate system the centreline
	// is given in, between a true circle and its polygonal approximation.
	Tol float64
}

// Stroker builds outlines. It keeps scratch memory between calls, so reuse
// one value for many strokes. The zero value is ready to use.
type Stroker struct {
	pts []geom.Point
}

const maxArcSteps = 2000

// Outline appends the pieces of the stroke of subs to out.
func (s *Stroker) Outline(out *geom.Polygons, subs []svgpath.Subpath, o Options) {
	r := o.Width / 2
	if !(r > 0) {
		return
	}
	ml := math.Max(o.MiterLimit, 1)
	step := arcStep(r, o.Tol)
	for _, sub := range subs {
		pts := s.dedup(sub)
		n := len(pts)
		switch {
		case n == 0:
			continue
		case n == 1:
			point(out, pts[0], r, o.Cap, step)
			continue
		}
		segs := n - 1
		if sub.Closed {
			segs = n
		}
		dir := func(i int) geom.Point {
			d := pts[(i+1)%n].Sub(pts[i])
			return d.Scale(1 / d.Len())
		}
		for i := 0; i < segs; i++ {
			a, b := pts[i], pts[(i+1)%n]
			nn := rot90(dir(i)).Scale(r)
			out.Add(a.Add(nn))
			out.Add(b.Add(nn))
			out.Add(b.Sub(nn))
			out.Add(a.Sub(nn))
			out.EndOriented()
		}
		if sub.Closed {
			for i := 0; i < n; i++ {
				join(out, pts[i], dir((i+n-1)%n), dir(i), r, o.Join, ml, step)
			}
		} else {
			for i := 1; i < n-1; i++ {
				join(out, pts[i], dir(i-1), dir(i), r, o.Join, ml, step)
			}
			capEnd(out, pts[0], dir(0).Scale(-1), r, o.Cap, step)
			capEnd(out, pts[n-1], dir(n-2), r, o.Cap, step)
		}
	}
}

// dedup copies the subpath points into scratch, dropping points equal to
// their predecessor and, for closed subpaths, a final point equal to the
// first.
func (s *Stroker) dedup(sub svgpath.Subpath) []geom.Point {
	s.pts = s.pts[:0]
	for _, p := range sub.Pts {
		if n := len(s.pts); n > 0 && s.pts[n-1] == p {
			continue
		}
		s.pts = append(s.pts, p)
	}
	if n := len(s.pts); sub.Closed && n > 1 && s.pts[n-1] == s.pts[0] {
		s.pts = s.pts[:n-1]
	}
	return s.pts
}

// rot90 rotates v a quarter turn.
func rot90(v geom.Point) geom.Point { return geom.Point{X: -v.Y, Y: v.X} }

// arcStep is the angular step whose chord deviates at most tol from a circle
// of radius r.
func arcStep(r, tol float64) float64 {
	x := 1 - tol/r
	if x <= -1 {
		return math.Pi
	}
	return 2 * math.Acos(x)
}

func arcCount(sweep, step float64, lo int) int {
	c := math.Ceil(math.Abs(sweep) / step)
	if !(c <= maxArcSteps) { // also catches NaN and +Inf
		return maxArcSteps
	}
	if c < float64(lo) {
		return lo
	}
	return int(c)
}

// addArc appends count+1 points of the circle of radius r about c, from angle
// a0 sweeping by sweep.
func addArc(out *geom.Polygons, c geom.Point, r, a0, sweep float64, count int) {
	for k := 0; k <= count; k++ {
		s, co := math.Sincos(a0 + sweep*float64(k)/float64(count))
		out.Add(geom.Point{X: c.X + r*co, Y: c.Y + r*s})
	}
}

// join emits the join piece at p between unit directions d0 (incoming) and
// d1 (outgoing).
func join(out *geom.Polygons, p, d0, d1 geom.Point, r float64, j Join, miterLimit, step float64) {
	cross, dot := d0.Cross(d1), d0.Dot(d1)
	if cross == 0 && dot > 0 {
		return
	}
	sg := -1.0
	if cross > 0 {
		sg = 1
	}
	a := geom.Point{X: d0.Y, Y: -d0.X}.Scale(sg * r)
	b := geom.Point{X: d1.Y, Y: -d1.X}.Scale(sg * r)
	A, B := p.Add(a), p.Add(b)
	switch j {
	case JoinRound:
		sweep := math.Atan2(a.Cross(b), a.Dot(b))
		if cross == 0 {
			sweep = sg * math.Pi
		}
		out.Add(p)
		addArc(out, p, r, math.Atan2(a.Y, a.X), sweep, arcCount(sweep, step, 1))
		out.EndOriented()
		return
	case JoinMiter:
		if dot > -1 && cross != 0 && 1/math.Sqrt((1+dot)/2) <= miterLimit {
			m := p.Add(a.Add(b).Scale(1 / (1 + dot)))
			out.Add(p)
			out.Add(A)
			out.Add(m)
			out.Add(B)
			out.EndOriented()
			return
		}
	}
	out.Add(p)
	out.Add(A)
	out.Add(B)
	out.EndOriented()
}

// capEnd emits the cap at the end point p of an open subpath, u being the
// unit direction pointing out of the subpath.
func capEnd(out *geom.Polygons, p, u geom.Point, r float64, c Cap, step float64) {
	switch c {
	case CapSquare:
		nn := rot90(u).Scale(r)
		ur := u.Scale(r)
		out.Add(p.Add(nn))
		out.Add(p.Add(nn).Add(ur))
		out.Add(p.Sub(nn).Add(ur))
		out.Add(p.Sub(nn))
		out.EndOriented()
	case CapRound:
		a0 := math.Atan2(u.Y, u.X) - math.Pi/2
		addArc(out, p, r, a0, math.Pi, arcCount(math.Pi, step, 1))
		out.EndOriented()
	}
}

// point emits the cap for a subpath that collapsed to one point.
func point(out *geom.Polygons, p geom.Point, r float64, c Cap, step float64) {
	switch c {
	case CapSquare:
		out.Add(geom.Point{X: p.X - r, Y: p.Y - r})
		out.Add(geom.Point{X: p.X + r, Y: p.Y - r})
		out.Add(geom.Point{X: p.X + r, Y: p.Y + r})
		out.Add(geom.Point{X: p.X - r, Y: p.Y + r})
		out.EndOriented()
	case CapRound:
		n := arcCount(2*math.Pi, step, 4)
		for k := 0; k < n; k++ {
			s, co := math.Sincos(2 * math.Pi * float64(k) / float64(n))
			out.Add(geom.Point{X: p.X + r*co, Y: p.Y + r*s})
		}
		out.EndOriented()
	}
}
