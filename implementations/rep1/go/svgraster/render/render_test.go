package render

import (
	"testing"

	"svgraster/geom"
	"svgraster/xmlmini"
)

func parse(t *testing.T, s string) *xmlmini.Node {
	t.Helper()
	n, err := xmlmini.Parse([]byte(s))
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestViewportMatrix(t *testing.T) {
	cases := []struct {
		svg  string
		want geom.Matrix
	}{
		{`<svg viewBox="10 20 50 25" width="1" height="1"/>`, geom.Matrix{A: 2, D: 2, E: -20, F: -40}},
		{`<svg width="50" height="25"/>`, geom.Matrix{A: 2, D: 2}},
		{`<svg width="50px"/>`, geom.Matrix{A: 1, D: 1}},
		{`<svg viewBox="0 0 0 5" width="200" height="50"/>`, geom.Matrix{A: .5, D: 1}},
	}
	for _, tc := range cases {
		w, h := 100, 50
		if got := ViewportMatrix(parse(t, tc.svg), w, h); got != tc.want {
			t.Errorf("%s: got %+v, want %+v", tc.svg, got, tc.want)
		}
	}
}

func TestRectRadii(t *testing.T) {
	segs := func(attrs string) int {
		p := ShapePath(parse(t, `<rect width="10" height="10" `+attrs+`/>`))
		if p == nil {
			return 0
		}
		return len(p.Segs)
	}
	if n := segs(""); n != 5 {
		t.Errorf("plain rect: %d segments", n)
	}
	if n := segs(`rx="auto" ry="auto"`); n != 5 {
		t.Errorf("auto radii: %d segments", n)
	}
	if n := segs(`rx="-3"`); n != 5 {
		t.Errorf("negative radius: %d segments", n)
	}
	if n := segs(`rx="2"`); n <= 5 {
		t.Errorf("rx alone should round the corners, %d segments", n)
	}
	if n := segs(`width="0"`); n != 0 {
		t.Errorf("zero width: %d segments", n)
	}
}

func TestShapePathDegenerate(t *testing.T) {
	for _, s := range []string{`<circle r="0"/>`, `<ellipse rx="3"/>`, `<polyline points=""/>`, `<g/>`} {
		if p := ShapePath(parse(t, s)); p != nil {
			t.Errorf("%s should produce no path", s)
		}
	}
}
