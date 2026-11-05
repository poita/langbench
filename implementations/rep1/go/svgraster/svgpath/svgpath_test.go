package svgpath

import (
	"math"
	"testing"

	"svgraster/geom"
)

func pts(p *Path) []geom.Point { return p.Pts }

func TestParseDataBasics(t *testing.T) {
	p := ParseData("M10 10 20 10 h-5 v5 z m1 1 l1 1")
	wantOps := []Op{OpMove, OpLine, OpLine, OpLine, OpClose, OpMove, OpLine}
	if len(p.Ops) != len(wantOps) {
		t.Fatalf("ops %v", p.Ops)
	}
	for i, o := range wantOps {
		if p.Ops[i] != o {
			t.Fatalf("ops %v, want %v", p.Ops, wantOps)
		}
	}
	// After z the current point is the start (10,10), so m1 1 -> (11,11).
	if got := pts(p)[4]; got != (geom.Point{X: 11, Y: 11}) {
		t.Errorf("relative move after close: %+v", got)
	}
}

func TestParseDataStopsAtError(t *testing.T) {
	p := ParseData("M0 0 L10 0 L10 x L20 20")
	if len(p.Ops) != 2 {
		t.Errorf("ops = %v", p.Ops)
	}
	p = ParseData("M0 0 L10 0 20")
	if len(p.Ops) != 2 {
		t.Errorf("partial group kept: %v", p.Ops)
	}
	p = ParseData("M0 0 L5 5 Z 7 7")
	if len(p.Ops) != 3 {
		t.Errorf("number after Z must stop the parse: %v", p.Ops)
	}
	if p := ParseData("L1 1"); len(p.Ops) != 0 {
		t.Error("path not starting with M drew something")
	}
}

func TestArcFlagsPacked(t *testing.T) {
	p := ParseData("M0 0 a5 5 0 0110 10")
	if got := p.Current(); got != (geom.Point{X: 10, Y: 10}) {
		t.Errorf("end = %+v", got)
	}
}

func TestSmoothAndQuad(t *testing.T) {
	p := ParseData("M0 0 C 0 10 10 10 10 0 S 20 -10 20 0")
	// Second cubic's first control is the reflection (10,-10) of (10,10) about (10,0).
	if c1 := p.Pts[4]; c1 != (geom.Point{X: 10, Y: -10}) {
		t.Errorf("S control = %+v", c1)
	}
	q := ParseData("M0 0 Q 6 0 6 6")
	c1, c2 := q.Pts[1], q.Pts[2]
	if math.Abs(c1.X-4) > 1e-12 || c1.Y != 0 || c2.X != 6 || math.Abs(c2.Y-2) > 1e-12 {
		t.Errorf("quad->cubic controls %+v %+v", c1, c2)
	}
}

func TestArcQuarterCircle(t *testing.T) {
	p := &Path{}
	p.MoveTo(geom.Point{X: 10, Y: 0})
	p.ArcTo(10, 10, 0, false, true, 0, 10)
	for _, s := range Flatten(p, geom.Identity, 0.01) {
		for _, pt := range s.Pts {
			if d := math.Hypot(pt.X, pt.Y); math.Abs(d-10) > 0.011 {
				t.Fatalf("point %+v off circle by %g", pt, d-10)
			}
		}
	}
	// Degenerate arcs.
	q := &Path{}
	q.MoveTo(geom.Point{})
	q.ArcTo(5, 5, 0, false, true, 0, 0)
	if len(q.Ops) != 1 {
		t.Error("arc with equal endpoints must be dropped")
	}
	q.ArcTo(0, 5, 0, false, true, 3, 3)
	if len(q.Ops) != 2 || q.Ops[1] != OpLine {
		t.Error("zero radius must give a line")
	}
}

func TestArcRadiiScaledUp(t *testing.T) {
	p := &Path{}
	p.MoveTo(geom.Point{})
	p.ArcTo(1, 1, 0, false, true, 10, 0) // radius too small: becomes a half circle of radius 5
	subs := Flatten(p, geom.Identity, 0.01)
	top := 0.0
	for _, pt := range subs[0].Pts {
		top = math.Max(top, math.Abs(pt.Y))
	}
	if math.Abs(top-5) > 0.02 {
		t.Errorf("half circle height %g, want 5", top)
	}
}

func TestFlattenLoneMoveAndCollapsedSubpath(t *testing.T) {
	subs := Flatten(ParseData("M1 1 M2 2 L2 2 M3 3 Z M4 4"), geom.Identity, 0.01)
	if len(subs) != 2 {
		t.Fatalf("subpaths = %d, want 2 (lone moves dropped)", len(subs))
	}
	if subs[0].Closed || !subs[1].Closed {
		t.Errorf("closed flags: %v %v", subs[0].Closed, subs[1].Closed)
	}
}

func TestFlattenTolerance(t *testing.T) {
	p := ParseData("M0 0 C 0 100 100 100 100 0")
	for _, tol := range []float64{0.01, 0.5} {
		pl := Flatten(p, geom.Identity, tol)[0].Pts
		for i := 0; i <= 200; i++ {
			tt := float64(i) / 200
			u := 1 - tt
			x := 3*u*tt*tt*100 + tt*tt*tt*100
			y := 3*u*u*tt*100 + 3*u*tt*tt*100
			best := math.Inf(1)
			for j := 0; j+1 < len(pl); j++ {
				best = math.Min(best, distSeg(geom.Point{X: x, Y: y}, pl[j], pl[j+1]))
			}
			if best > tol {
				t.Fatalf("tol %g: curve point t=%g is %g from the polyline", tol, tt, best)
			}
		}
	}
}

func distSeg(p, a, b geom.Point) float64 {
	ab := b.Sub(a)
	t := math.Max(0, math.Min(1, p.Sub(a).Dot(ab)/ab.Dot(ab)))
	return p.Sub(a.Add(ab.Scale(t))).Len()
}

func TestShapes(t *testing.T) {
	if r := Rect(0, 0, 4, 2, 0, 0); len(r.Ops) != 5 {
		t.Errorf("plain rect ops %v", r.Ops)
	}
	if r := Rect(0, 0, 4, 2, 1, 1); r.Ops[len(r.Ops)-1] != OpClose || len(r.Ops) < 9 {
		t.Errorf("rounded rect ops %v", r.Ops)
	}
	if Poly([]float64{1}, false) != nil {
		t.Error("poly with no points must be nil")
	}
	if p := Poly([]float64{0, 0, 1, 1, 2}, true); len(p.Ops) != 3 {
		t.Errorf("odd trailing number: %v", p.Ops)
	}
}
