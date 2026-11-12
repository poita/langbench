// Package stroke builds stroke outlines from flattened paths.
//
// The outline of a stroke is returned as a set of simple polygons whose union
// (a nonzero-winding fill after orienting each polygon consistently) is the
// stroked region: one rectangle per segment, one piece per join and one per
// cap, as described in the package documentation of Outline.
package stroke

import (
	"math"

	"svgraster/geom"
	"svgraster/path"
)

// Cap is a line cap style.
type Cap uint8

// Line cap styles.
const (
	ButtCap Cap = iota
	RoundCap
	SquareCap
)

// Join is a line join style.
type Join uint8

// Line join styles.
const (
	MiterJoin Join = iota
	RoundJoin
	BevelJoin
)

// Style holds the stroke parameters.
type Style struct {
	Width      float64
	Cap        Cap
	Join       Join
	MiterLimit float64
}

// Outline converts flattened subpaths into polygons covering the stroke.
// Coordinates are in the same space as the subpaths; tol is the maximum
// distance by which circular arcs may deviate from the true circle.
//
// For every subpath, consecutive duplicate points are dropped (and a closing
// point equal to the first). Then:
//   - each segment contributes a rectangle of the stroke width;
//   - each interior vertex (all vertices of a closed subpath) contributes a
//     join piece (none for collinear continuation);
//   - each end of an open subpath contributes a cap piece;
//   - a subpath that collapses to a single point contributes a disc (round
//     cap), a square (square cap) or nothing (butt cap).
func Outline(subs []path.Subpath, st Style, tol float64) [][]geom.Point {
	b := &builder{st: st, r: st.Width / 2, tol: tol}
	if b.st.MiterLimit < 1 {
		b.st.MiterLimit = 1
	}
	for _, sp := range subs {
		b.subpath(sp)
	}
	return b.polys
}

type builder struct {
	st    Style
	r     float64
	tol   float64
	polys [][]geom.Point
}

func (b *builder) add(pts ...geom.Point) {
	b.polys = append(b.polys, pts)
}

func (b *builder) subpath(sp path.Subpath) {
	pts := make([]geom.Point, 0, len(sp.Points))
	for _, p := range sp.Points {
		if len(pts) == 0 || p != pts[len(pts)-1] {
			pts = append(pts, p)
		}
	}
	if sp.Closed && len(pts) > 1 && pts[len(pts)-1] == pts[0] {
		pts = pts[:len(pts)-1]
	}
	n := len(pts)
	if n == 0 {
		return
	}
	if n == 1 {
		b.point(pts[0])
		return
	}
	nseg := n - 1
	if sp.Closed {
		nseg = n
	}
	dirs := make([]geom.Point, nseg)
	for i := 0; i < nseg; i++ {
		a, c := pts[i], pts[(i+1)%n]
		d := c.Sub(a)
		dirs[i] = d.Scale(1 / d.Len())
		nrm := geom.Point{X: -dirs[i].Y, Y: dirs[i].X}.Scale(b.r)
		b.add(a.Add(nrm), c.Add(nrm), c.Sub(nrm), a.Sub(nrm))
	}
	if sp.Closed {
		for i := 0; i < n; i++ {
			b.join(pts[i], dirs[(i+nseg-1)%nseg], dirs[i])
		}
		return
	}
	for i := 1; i < n-1; i++ {
		b.join(pts[i], dirs[i-1], dirs[i])
	}
	b.cap(pts[0], dirs[0].Scale(-1))
	b.cap(pts[n-1], dirs[nseg-1])
}

// point handles a subpath that collapsed to a single point.
func (b *builder) point(p geom.Point) {
	r := b.r
	switch b.st.Cap {
	case RoundCap:
		b.add(b.arc(p, 0, 2*math.Pi, true)...)
	case SquareCap:
		b.add(geom.Point{X: p.X - r, Y: p.Y - r}, geom.Point{X: p.X + r, Y: p.Y - r},
			geom.Point{X: p.X + r, Y: p.Y + r}, geom.Point{X: p.X - r, Y: p.Y + r})
	}
}

// cap adds the cap at end point p; u is the unit direction pointing out of
// the subpath.
func (b *builder) cap(p, u geom.Point) {
	r := b.r
	nrm := geom.Point{X: -u.Y, Y: u.X}.Scale(r)
	switch b.st.Cap {
	case SquareCap:
		ext := u.Scale(r)
		b.add(p.Add(nrm), p.Add(nrm).Add(ext), p.Sub(nrm).Add(ext), p.Sub(nrm))
	case RoundCap:
		// Half disc from +nrm through u to -nrm.
		start := math.Atan2(nrm.Y, nrm.X)
		pts := b.arc(p, start, -math.Pi, false)
		b.add(pts...)
	}
}

// join adds the join piece at p between incoming direction d0 and outgoing
// direction d1 (both unit vectors).
func (b *builder) join(p, d0, d1 geom.Point) {
	cross := d0.Cross(d1)
	dot := d0.Dot(d1)
	if cross == 0 && dot > 0 {
		return
	}
	s := 1.0
	if !(cross > 0) {
		s = -1
	}
	r := b.r
	A := p.Add(geom.Point{X: d0.Y, Y: -d0.X}.Scale(s * r))
	B := p.Add(geom.Point{X: d1.Y, Y: -d1.X}.Scale(s * r))
	join := b.st.Join
	if join == MiterJoin {
		ratio := 1 / math.Sqrt((1+dot)/2)
		if dot > -1 && cross != 0 && ratio <= b.st.MiterLimit {
			t := B.Sub(A).Cross(d1) / cross
			M := A.Add(d0.Scale(t))
			b.add(p, A, M, B)
			return
		}
		join = BevelJoin
	}
	if join == BevelJoin {
		b.add(p, A, B)
		return
	}
	// Round: sector from A to B about p.
	a0 := math.Atan2(A.Y-p.Y, A.X-p.X)
	// The signed angle from A-p to B-p equals the turn angle from d0 to d1;
	// computing it from cross and dot stays accurate for near-reversals.
	sweep := math.Atan2(cross, dot)
	if cross == 0 {
		sweep = s * math.Pi
	}
	poly := []geom.Point{p}
	poly = append(poly, b.arc(p, a0, sweep, false)...)
	b.add(poly...)
}

// arc returns points on the circle of radius r about c, starting at angle a0
// and sweeping by sweep radians, including both end points. When full is set
// the final point (equal to the first) is omitted.
func (b *builder) arc(c geom.Point, a0, sweep float64, full bool) []geom.Point {
	r := b.r
	step := math.Pi / 2
	if b.tol < r {
		step = 2 * math.Acos(1-b.tol/r)
	}
	if !(step > 1e-3) {
		step = 1e-3
	}
	n := int(math.Ceil(math.Abs(sweep) / step))
	if n < 1 {
		n = 1
	}
	cnt := n + 1
	if full {
		cnt = n
	}
	pts := make([]geom.Point, 0, cnt)
	for i := 0; i < cnt; i++ {
		a := a0 + sweep*float64(i)/float64(n)
		s, co := math.Sincos(a)
		pts = append(pts, geom.Point{X: c.X + r*co, Y: c.Y + r*s})
	}
	return pts
}
