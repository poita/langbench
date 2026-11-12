package svgparse

import (
	"math"
	"testing"

	"svgraster/geom"
)

func TestScanNumber(t *testing.T) {
	tests := []struct {
		in string
		v  float64
		n  int
	}{
		{"5", 5, 1}, {".5", .5, 2}, {"5.", 5, 2}, {"-5.25x", -5.25, 5},
		{"1e3", 1000, 3}, {"1e", 1, 1}, {"1e+", 1, 1}, {"2E-2", .02, 4},
		{"+.5e1", 5, 5}, {".", 0, 0}, {"-", 0, 0}, {"abc", 0, 0}, {"1.5.5", 1.5, 3},
	}
	for _, tc := range tests {
		v, n := ScanNumber(tc.in)
		if v != tc.v || n != tc.n {
			t.Errorf("ScanNumber(%q) = %v, %d; want %v, %d", tc.in, v, n, tc.v, tc.n)
		}
	}
}

func TestParseLength(t *testing.T) {
	for in, want := range map[string]float64{" 12px ": 12, "3": 3, "-1.5": -1.5} {
		if v, ok := ParseLength(in); !ok || v != want {
			t.Errorf("ParseLength(%q) = %v, %v", in, v, ok)
		}
	}
	if _, ok := ParseLength("px"); ok {
		t.Error("expected failure")
	}
}

func TestParseOpacity(t *testing.T) {
	cases := []struct {
		in string
		v  float64
		ok bool
	}{
		{"0.5", .5, true}, {"50%", .5, true}, {"2", 1, true}, {"-1", 0, true},
		{"150%", 1, true}, {"0.5x", 0, false}, {"", 0, false}, {"abc", 0, false},
	}
	for _, tc := range cases {
		v, ok := ParseOpacity(tc.in)
		if ok != tc.ok || (ok && v != tc.v) {
			t.Errorf("ParseOpacity(%q) = %v, %v; want %v, %v", tc.in, v, ok, tc.v, tc.ok)
		}
	}
}

func TestColors(t *testing.T) {
	if len(namedColors) != 147 {
		t.Errorf("named colours = %d, want 147", len(namedColors))
	}
	cases := map[string]Color{
		"#f39":                 {255, 51, 153},
		"#FF3399":              {255, 51, 153},
		"RED":                  {255, 0, 0},
		"rebeccapurple":        {},
		"rgb(1, 2, 3)":         {1, 2, 3},
		"rgb(300 -5 127.5)":    {255, 0, 128},
		"rgb(50%,100%,0.5%)":   {128, 255, 1},
		"LightGoldenRodYellow": {250, 250, 210},
	}
	for in, want := range cases {
		c, ok := ParseColor(in)
		if want == (Color{}) {
			if ok {
				t.Errorf("ParseColor(%q) should fail", in)
			}
			continue
		}
		if !ok || c != want {
			t.Errorf("ParseColor(%q) = %v, %v; want %v", in, c, ok, want)
		}
	}
	for _, bad := range []string{"#12", "#12345g", "rgb(1,2)", "", "url(#a)"} {
		if _, ok := ParseColor(bad); ok {
			t.Errorf("ParseColor(%q) should fail", bad)
		}
	}
}

func TestParsePaint(t *testing.T) {
	if p, ok := ParsePaint(" None "); !ok || !p.None {
		t.Error("none")
	}
	if p, ok := ParsePaint("currentcolor"); !ok || !p.Current {
		t.Error("currentColor")
	}
	if p, ok := ParsePaint("blue"); !ok || p.Color != (Color{0, 0, 255}) {
		t.Error("blue")
	}
}

func TestParseStyle(t *testing.T) {
	d := ParseStyle("Fill : red;;stroke:blue; junk ; opacity: ;fill-rule:evenodd;")
	want := Declarations{"fill": "red", "stroke": "blue", "fill-rule": "evenodd"}
	if len(d) != len(want) {
		t.Fatalf("got %v", d)
	}
	for k, v := range want {
		if d[k] != v {
			t.Errorf("%s = %q, want %q", k, d[k], v)
		}
	}
}

func approx(a, b geom.Matrix) bool {
	return math.Abs(a.A-b.A) < 1e-9 && math.Abs(a.B-b.B) < 1e-9 && math.Abs(a.C-b.C) < 1e-9 &&
		math.Abs(a.D-b.D) < 1e-9 && math.Abs(a.E-b.E) < 1e-9 && math.Abs(a.F-b.F) < 1e-9
}

func TestParseTransform(t *testing.T) {
	cases := []struct {
		in   string
		want geom.Matrix
	}{
		{"", geom.Identity},
		{"translate(3)", geom.Matrix{A: 1, D: 1, E: 3}},
		{"scale(2)", geom.Matrix{A: 2, D: 2}},
		{"matrix(1 2 3 4 5 6)", geom.Matrix{A: 1, B: 2, C: 3, D: 4, E: 5, F: 6}},
		{"translate(10,20) scale(2 3)", geom.Matrix{A: 2, D: 3, E: 10, F: 20}},
		{"rotate(90)", geom.Matrix{B: 1, C: -1}},
		{"rotate(90 1 1)", geom.Matrix{B: 1, C: -1, E: 2}},
		{"skewX(45)", geom.Matrix{A: 1, C: 1, D: 1}},
		{"bogus(1) translate(1 2),translate(1)", geom.Matrix{A: 1, D: 1, E: 2, F: 2}},
		{"matrix(1 2 3)", geom.Identity},
	}
	for _, tc := range cases {
		if got := ParseTransform(tc.in); !approx(got, tc.want) {
			t.Errorf("ParseTransform(%q) = %+v, want %+v", tc.in, got, tc.want)
		}
	}
}

func TestViewBox(t *testing.T) {
	if x, y, w, h, ok := ViewBox("0,0 10 20"); !ok || x != 0 || y != 0 || w != 10 || h != 20 {
		t.Error("simple view box")
	}
	for _, bad := range []string{"0 0 0 5", "0 0 5", "a b c d"} {
		if _, _, _, _, ok := ViewBox(bad); ok {
			t.Errorf("ViewBox(%q) should fail", bad)
		}
	}
}
