package stroke

import (
	"math"
	"testing"

	"svgraster/geom"
	"svgraster/svgpath"
)

func line(pts ...float64) []svgpath.Subpath {
	var s svgpath.Subpath
	for i := 0; i+1 < len(pts); i += 2 {
		s.Pts = append(s.Pts, geom.Point{X: pts[i], Y: pts[i+1]})
	}
	return []svgpath.Subpath{s}
}

func area(g *geom.Polygons, i int) float64 {
	p := g.Poly(i)
	a := 0.0
	for k := range p {
		q := p[(k+1)%len(p)]
		a += p[k].X*q.Y - q.X*p[k].Y
	}
	return a / 2
}

func TestSegmentRectangle(t *testing.T) {
	var g geom.Polygons
	var s Stroker
	s.Outline(&g, line(0, 0, 10, 0), Options{Width: 2, Tol: 0.01})
	if g.Len() != 1 {
		t.Fatalf("pieces = %d", g.Len())
	}
	if a := area(&g, 0); math.Abs(a-20) > 1e-9 {
		t.Errorf("area = %g, want 20", a)
	}
}

func TestPiecesArePositivelyOriented(t *testing.T) {
	var g geom.Polygons
	var s Stroker
	sub := line(0, 0, 10, 0, 10, 10, 0, 10)
	sub[0].Closed = true
	for _, j := range []Join{JoinMiter, JoinRound, JoinBevel} {
		g.Reset()
		s.Outline(&g, sub, Options{Width: 2, Join: j, MiterLimit: 4, Tol: 0.01})
		for i := 0; i < g.Len(); i++ {
			if area(&g, i) < 0 {
				t.Fatalf("join %d piece %d has negative area", j, i)
			}
		}
	}
}

func TestCapsAndPoints(t *testing.T) {
	var s Stroker
	count := func(sub []svgpath.Subpath, c Cap) int {
		var g geom.Polygons
		s.Outline(&g, sub, Options{Width: 2, Cap: c, Tol: 0.01})
		return g.Len()
	}
	seg := line(0, 0, 10, 0)
	if n := count(seg, CapButt); n != 1 {
		t.Errorf("butt pieces = %d", n)
	}
	if n := count(seg, CapSquare); n != 3 {
		t.Errorf("square pieces = %d", n)
	}
	if n := count(seg, CapRound); n != 3 {
		t.Errorf("round pieces = %d", n)
	}
	dot := line(5, 5, 5, 5)
	if n := count(dot, CapButt); n != 0 {
		t.Errorf("butt dot pieces = %d", n)
	}
	var g geom.Polygons
	s.Outline(&g, dot, Options{Width: 2, Cap: CapSquare, Tol: 0.01})
	if a := area(&g, 0); math.Abs(a-4) > 1e-9 {
		t.Errorf("square dot area = %g", a)
	}
	g.Reset()
	s.Outline(&g, dot, Options{Width: 2, Cap: CapRound, Tol: 0.01})
	if a := area(&g, 0); math.Abs(a-math.Pi) > 0.05 {
		t.Errorf("round dot area = %g", a)
	}
}

func TestMiterLimit(t *testing.T) {
	// A right angle has miter ratio sqrt(2) ~ 1.414; limit 1.2 forces a bevel.
	sub := line(0, 0, 10, 0, 10, 10)
	miterArea := func(limit float64) float64 {
		var g geom.Polygons
		var s Stroker
		s.Outline(&g, sub, Options{Width: 2, Join: JoinMiter, MiterLimit: limit, Tol: 0.01})
		return area(&g, 2) // third piece is the join
	}
	if a := miterArea(4); math.Abs(a-1) > 1e-9 { // kite p,A,M,B with r=1
		t.Errorf("miter piece area %g, want 1", a)
	}
	if a := miterArea(1.2); math.Abs(a-0.5) > 1e-9 { // bevel triangle
		t.Errorf("bevel piece area %g, want 0.5", a)
	}
	if mi, be := miterArea(4), miterArea(1.2); !(mi > be) {
		t.Errorf("miter %g should exceed bevel %g", mi, be)
	}
}

func TestZeroWidth(t *testing.T) {
	var g geom.Polygons
	var s Stroker
	s.Outline(&g, line(0, 0, 1, 1), Options{Width: 0})
	if g.Len() != 0 {
		t.Error("zero width produced geometry")
	}
}
