package path

import (
	"math"
	"testing"

	"svgraster/geom"
)

func kinds(p *Path) []Kind {
	var ks []Kind
	for _, s := range p.Segs {
		ks = append(ks, s.Kind)
	}
	return ks
}

func equalKinds(a, b []Kind) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestParseImplicitAndRelative(t *testing.T) {
	p := Parse("m1 2 3 4 5 6 h10 v-1 z")
	if !equalKinds(kinds(p), []Kind{MoveTo, LineTo, LineTo, LineTo, LineTo, Close}) {
		t.Fatalf("kinds = %v", kinds(p))
	}
	want := []geom.Point{{X: 1, Y: 2}, {X: 4, Y: 6}, {X: 9, Y: 12}, {X: 19, Y: 12}, {X: 19, Y: 11}}
	for i, w := range want {
		if p.Segs[i].P[0] != w {
			t.Errorf("seg %d = %v, want %v", i, p.Segs[i].P[0], w)
		}
	}
}

func TestParseStopsAtGarbage(t *testing.T) {
	p := Parse("M0 0 L10 10 L5 x L20 20")
	if len(p.Segs) != 2 {
		t.Errorf("segs = %d, want 2", len(p.Segs))
	}
	p = Parse("M0 0 L10 10 Z 5 5")
	if !equalKinds(kinds(p), []Kind{MoveTo, LineTo, Close}) {
		t.Errorf("number after Z should stop the parse: %v", kinds(p))
	}
	p = Parse("M0 0 L10") // incomplete group dropped
	if len(p.Segs) != 1 {
		t.Errorf("segs = %d, want 1", len(p.Segs))
	}
	if p = Parse("L1 1"); len(p.Segs) != 0 {
		t.Error("path must start with a moveto")
	}
}

func TestArcFlags(t *testing.T) {
	p := Parse("M0 0 a5 5 0 0110 10")
	if len(p.Segs) < 2 {
		t.Fatalf("no arc produced: %v", kinds(p))
	}
	end := p.Segs[len(p.Segs)-1].P[2]
	if math.Abs(end.X-10) > 1e-9 || math.Abs(end.Y-10) > 1e-9 {
		t.Errorf("arc end = %v, want (10,10)", end)
	}
}

func TestSmoothAndQuad(t *testing.T) {
	p := Parse("M0 0 C0 10 10 10 10 0 S20 -10 20 0")
	c1 := p.Segs[2].P[0]
	if c1 != (geom.Point{X: 10, Y: -10}) {
		t.Errorf("S first control = %v, want reflection (10,-10)", c1)
	}
	p = Parse("M0 0 Q3 3 6 0")
	s := p.Segs[1]
	if s.P[0] != (geom.Point{X: 2, Y: 2}) || s.P[1] != (geom.Point{X: 4, Y: 2}) {
		t.Errorf("quad as cubic = %v", s.P)
	}
	p = Parse("M0 0 L5 5 S10 10 20 0") // previous not a cubic: control = current point
	if p.Segs[2].P[0] != (geom.Point{X: 5, Y: 5}) {
		t.Errorf("S after L control = %v", p.Segs[2].P[0])
	}
}

func TestArcDegenerate(t *testing.T) {
	p := Parse("M5 5 A3 3 0 0 1 5 5")
	if len(p.Segs) != 1 {
		t.Errorf("arc to the same point should vanish, got %v", kinds(p))
	}
	p = Parse("M0 0 A0 3 0 0 1 5 5")
	if !equalKinds(kinds(p), []Kind{MoveTo, LineTo}) {
		t.Errorf("zero radius should give a line, got %v", kinds(p))
	}
}

func TestFlattenWithinTolerance(t *testing.T) {
	c := Ellipse(50, 50, 40, 40)
	subs := c.Flatten(geom.Identity, 0.01)
	if len(subs) != 1 || !subs[0].Closed {
		t.Fatalf("subpaths = %+v", subs)
	}
	for _, pt := range subs[0].Points {
		d := math.Hypot(pt.X-50, pt.Y-50)
		if math.Abs(d-40) > 0.01+1e-3 {
			t.Fatalf("point %v at distance %v from centre", pt, d)
		}
	}
}

func TestFlattenSubpathRules(t *testing.T) {
	// Lone moveto yields nothing; M Z yields a closed single point; drawing
	// after Z restarts at the closed subpath's start point.
	p := Parse("M1 1 M2 2 Z L5 5 M9 9")
	subs := p.Flatten(geom.Identity, 0.01)
	if len(subs) != 2 {
		t.Fatalf("subpaths = %+v", subs)
	}
	if !subs[0].Closed || len(subs[0].Points) != 1 {
		t.Errorf("first = %+v", subs[0])
	}
	if subs[1].Closed || len(subs[1].Points) != 2 || subs[1].Points[0] != (geom.Point{X: 2, Y: 2}) {
		t.Errorf("second = %+v", subs[1])
	}
}

func TestShapes(t *testing.T) {
	if Rect(0, 0, 0, 5, 0, 0) != nil || Ellipse(0, 0, 1, 0) != nil || Poly(nil, true) != nil {
		t.Error("degenerate shapes should be nil")
	}
	if n := len(Rect(0, 0, 10, 10, 0, 0).Segs); n != 5 {
		t.Errorf("plain rect segs = %d", n)
	}
	r := Rect(0, 0, 10, 10, 2, 2)
	last := r.Segs[len(r.Segs)-2]
	if e := last.P[2]; math.Abs(e.X-2) > 1e-9 || e.Y != 0 {
		t.Errorf("rounded rect should end at (2,0), got %v", e)
	}
	if p := Poly([]float64{1, 2, 3, 4, 5}, true); len(p.Segs) != 3 {
		t.Errorf("odd coordinate should be dropped: %d segs", len(p.Segs))
	}
}
