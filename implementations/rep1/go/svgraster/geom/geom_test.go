package geom

import (
	"math"
	"testing"
)

func near(a, b Point) bool { return math.Abs(a.X-b.X) < 1e-12 && math.Abs(a.Y-b.Y) < 1e-12 }

func TestMatrixMulOrder(t *testing.T) {
	m := Translate(10, 0).Mul(Scale(2, 2)) // scale first, then translate
	if got := m.Apply(Point{1, 1}); !near(got, Point{12, 2}) {
		t.Errorf("got %+v", got)
	}
	if got := Rotate(90).Apply(Point{1, 0}); !near(got, Point{0, 1}) {
		t.Errorf("rotate: %+v", got)
	}
	if s := (Matrix{A: 3, D: 4}).MaxScale(); s != 4 {
		t.Errorf("MaxScale = %g", s)
	}
}

func TestPolygons(t *testing.T) {
	var g Polygons
	g.Add(Point{0, 0})
	g.Add(Point{0, 1})
	g.Add(Point{1, 1})
	g.Add(Point{1, 0}) // clockwise on paper: negative shoelace sum
	g.EndOriented()
	g.Add(Point{5, 5})
	g.End()
	if g.Len() != 2 || len(g.Poly(0)) != 4 || len(g.Poly(1)) != 1 {
		t.Fatalf("layout: %+v", g.Ends)
	}
	p := g.Poly(0)
	a := 0.0
	for i := range p {
		q := p[(i+1)%len(p)]
		a += p[i].X*q.Y - q.X*p[i].Y
	}
	if a <= 0 {
		t.Errorf("polygon not reoriented, area*2 = %g", a)
	}
	g.Transform(Translate(1, 1))
	if g.Poly(1)[0] != (Point{6, 6}) {
		t.Errorf("transform: %+v", g.Poly(1)[0])
	}
	g.Reset()
	if g.Len() != 0 || len(g.Pts) != 0 {
		t.Error("Reset")
	}
}
