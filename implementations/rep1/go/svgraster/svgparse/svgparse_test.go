package svgparse

import (
	"math"
	"reflect"
	"testing"

	"svgraster/geom"
)

func TestScanNumber(t *testing.T) {
	cases := []struct {
		in   string
		v    float64
		rest string
		ok   bool
	}{
		{"5", 5, "", true},
		{".5", .5, "", true},
		{"5.", 5, "", true},
		{"-5.25e2x", -525, "x", true},
		{"1e", 1, "e", true},
		{"1e+", 1, "e+", true},
		{"1.5.5", 1.5, ".5", true},
		{"+.", 0, "", false},
		{"e5", 0, "", false},
	}
	for _, c := range cases {
		v, n, ok := ScanNumber(c.in, 0)
		if ok != c.ok || (ok && (v != c.v || c.in[n:] != c.rest)) {
			t.Errorf("ScanNumber(%q) = %v,%q,%v", c.in, v, c.in[n:], ok)
		}
	}
}

func TestNumberList(t *testing.T) {
	got := NumberList(" 1,2 3 ,-4.5e1 x 9")
	if !reflect.DeepEqual(got, []float64{1, 2, 3, -45}) {
		t.Errorf("got %v", got)
	}
}

func TestLengthOpacity(t *testing.T) {
	if v, ok := Length(" 12px "); !ok || v != 12 {
		t.Errorf("Length = %v %v", v, ok)
	}
	if _, ok := Length("abc"); ok {
		t.Error("Length(abc) ok")
	}
	for in, want := range map[string]float64{"0.5": .5, "50%": .5, "2": 1, "-1": 0, " 25% ": .25} {
		if v, ok := Opacity(in); !ok || math.Abs(v-want) > 1e-12 {
			t.Errorf("Opacity(%q) = %v %v", in, v, ok)
		}
	}
	for _, in := range []string{"", "x", "0.5px", "5%%"} {
		if _, ok := Opacity(in); ok {
			t.Errorf("Opacity(%q) ok", in)
		}
	}
}

func TestColors(t *testing.T) {
	cases := map[string]Paint{
		"#f39":                 {PaintRGB, RGB{0xff, 0x33, 0x99}},
		"#FF3399":              {PaintRGB, RGB{0xff, 0x33, 0x99}},
		"rgb(10, 20 ,300)":     {PaintRGB, RGB{10, 20, 255}},
		"rgb(50% 100% -5%)":    {PaintRGB, RGB{128, 255, 0}},
		"rgb(0.5,1.5,2.5)":     {PaintRGB, RGB{1, 2, 3}},
		"RED":                  {PaintRGB, RGB{255, 0, 0}},
		"  CornflowerBlue ":    {PaintRGB, RGB{0x64, 0x95, 0xed}},
		"none":                 {Kind: PaintNone},
		"CurrentColor":         {Kind: PaintCurrent},
		"lightgoldenrodyellow": {PaintRGB, RGB{0xfa, 0xfa, 0xd2}},
	}
	for in, want := range cases {
		got, ok := ParseColor(in)
		if !ok || got != want {
			t.Errorf("ParseColor(%q) = %+v %v, want %+v", in, got, ok, want)
		}
	}
	for _, in := range []string{"", "#12", "#gggggg", "rgb(1,2)", "notacolor", "url(#a)"} {
		if _, ok := ParseColor(in); ok {
			t.Errorf("ParseColor(%q) ok", in)
		}
	}
}

func TestColorTableSize(t *testing.T) {
	if len(namedColors) != 147 {
		t.Errorf("%d colour names, want 147", len(namedColors))
	}
}

func TestTransform(t *testing.T) {
	m := Transform("translate(10 20), scale(2) bogus(1) rotate(90)")
	p := m.Apply(geom.Point{X: 1, Y: 0}) // rotate -> (0,1); scale -> (0,2); translate -> (10,22)
	if math.Abs(p.X-10) > 1e-9 || math.Abs(p.Y-22) > 1e-9 {
		t.Errorf("got %+v", p)
	}
	r := Transform("rotate(90 5 5)").Apply(geom.Point{X: 6, Y: 5})
	if math.Abs(r.X-5) > 1e-9 || math.Abs(r.Y-6) > 1e-9 {
		t.Errorf("rotate about centre: %+v", r)
	}
	if got := Transform("translate()"); got != geom.Identity {
		t.Errorf("empty args not skipped: %+v", got)
	}
	if got := Transform("skewX(45)"); math.Abs(got.C-1) > 1e-12 {
		t.Errorf("skewX: %+v", got)
	}
}

func TestStyle(t *testing.T) {
	var got [][2]string
	Style("Fill : red;; stroke:blue;bad;empty: ;", func(n, v string) { got = append(got, [2]string{n, v}) })
	want := [][2]string{{"fill", "red"}, {"stroke", "blue"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v", got)
	}
}
