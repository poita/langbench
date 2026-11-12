package raster

import (
	"bytes"
	"math"
	"testing"

	"svgraster/geom"
)

func rect(x0, y0, x1, y1 float64) []geom.Point {
	return []geom.Point{{X: x0, Y: y0}, {X: x1, Y: y0}, {X: x1, Y: y1}, {X: x0, Y: y1}}
}

func TestFractionalCoverage(t *testing.T) {
	r := NewRasterizer(8, 4)
	got := map[int][]float64{}
	r.Fill([][]geom.Point{rect(1, 1, 4.5, 3)}, NonZero, func(y, x0 int, cov []float64) {
		row := make([]float64, 8)
		copy(row[x0:], cov)
		got[y] = row
	})
	want := []float64{0, 1, 1, 1, .5, 0, 0, 0}
	for _, y := range []int{1, 2} {
		for x, w := range want {
			if math.Abs(got[y][x]-w) > 1e-12 {
				t.Errorf("(%d,%d) = %v, want %v", x, y, got[y][x], w)
			}
		}
	}
	if len(got) != 2 {
		t.Errorf("rows emitted = %d, want 2", len(got))
	}
}

func TestSlantedEdgeArea(t *testing.T) {
	tri := []geom.Point{{X: 0, Y: 0}, {X: 10, Y: 0}, {X: 0, Y: 10}}
	c := NewCanvas(10, 10)
	c.FillPolygons([][]geom.Point{tri}, NonZero, [3]float64{}, 1)
	sum := 0.0
	for i := 3; i < len(c.Pix); i += 4 {
		sum += c.Pix[i]
	}
	if math.Abs(sum-50) > 0.1 {
		t.Errorf("triangle area = %v, want 50", sum)
	}
}

func TestFillRules(t *testing.T) {
	// Two nested squares with the same orientation.
	polys := [][]geom.Point{rect(0, 0, 10, 10), rect(3, 3, 7, 7)}
	centre := func(rule FillRule) float64 {
		c := NewCanvas(10, 10)
		c.FillPolygons(polys, rule, [3]float64{}, 1)
		return c.Pix[(5*10+5)*4+3]
	}
	if centre(NonZero) != 1 || centre(EvenOdd) != 0 {
		t.Errorf("nonzero %v evenodd %v", centre(NonZero), centre(EvenOdd))
	}
}

func TestClipping(t *testing.T) {
	c := NewCanvas(4, 4)
	c.FillPolygons([][]geom.Point{rect(-100, -100, 100, 100)}, NonZero, [3]float64{1, 0, 0}, 1)
	for i := 3; i < len(c.Pix); i += 4 {
		if c.Pix[i] != 1 {
			t.Fatalf("pixel %d alpha %v", i/4, c.Pix[i])
		}
	}
	c.FillPolygons([][]geom.Point{rect(10, 10, 20, 20), {{X: math.NaN(), Y: 0}, {X: 1, Y: 1}, {X: 2, Y: 0}}},
		NonZero, [3]float64{}, 1) // must not panic
}

func TestSourceOverAndOutput(t *testing.T) {
	c := NewCanvas(1, 1)
	sq := [][]geom.Point{rect(0, 0, 1, 1)}
	c.FillPolygons(sq, NonZero, [3]float64{1, 0, 0}, 0.5)
	c.FillPolygons(sq, NonZero, [3]float64{0, 0, 1}, 0.5)
	// red: (.5,0,0,.5); then blue: r=.25, b=.5, a=.75
	want := [4]float64{.25, 0, .5, .75}
	for i, w := range want {
		if math.Abs(c.Pix[i]-w) > 1e-12 {
			t.Errorf("channel %d = %v, want %v", i, c.Pix[i], w)
		}
	}
	img := c.ToImage()
	// v = channel + (1 - a): .25+.25=.5 -> 128; 0+.25 -> 64; .5+.25=.75 -> 191
	if !bytes.Equal(img.Pix, []byte{128, 64, 191}) {
		t.Errorf("pixel = %v", img.Pix)
	}
}

func TestDrawLayerAndClear(t *testing.T) {
	dst := NewCanvas(2, 2)
	layer := NewCanvas(2, 2)
	layer.FillPolygons([][]geom.Point{rect(0, 0, 2, 2)}, NonZero, [3]float64{0, 0, 1}, 1)
	dst.DrawLayer(layer, 0.5)
	if dst.Pix[2] != 0.5 || dst.Pix[3] != 0.5 {
		t.Errorf("composited = %v", dst.Pix[:4])
	}
	layer.Clear()
	for _, v := range layer.Pix {
		if v != 0 {
			t.Fatal("layer not cleared")
		}
	}
}

func TestWritePPM(t *testing.T) {
	img := &Image{W: 2, H: 1, Pix: []byte{1, 2, 3, 4, 5, 6}}
	var b bytes.Buffer
	if err := img.WritePPM(&b); err != nil {
		t.Fatal(err)
	}
	if want := "P6\n2 1\n255\n\x01\x02\x03\x04\x05\x06"; b.String() != want {
		t.Errorf("got %q", b.String())
	}
}

func TestOrient(t *testing.T) {
	ccw := []geom.Point{{X: 0, Y: 0}, {X: 0, Y: 1}, {X: 1, Y: 1}, {X: 1, Y: 0}}
	flat := []geom.Point{{X: 0, Y: 0}, {X: 1, Y: 1}, {X: 2, Y: 2}}
	out := Orient([][]geom.Point{ccw, flat})
	if len(out) != 1 || SignedArea(out[0]) <= 0 {
		t.Errorf("Orient = %v", out)
	}
}
