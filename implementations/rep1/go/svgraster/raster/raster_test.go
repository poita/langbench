package raster

import (
	"bytes"
	"math"
	"testing"

	"svgraster/geom"
)

func rectPolys(x0, y0, x1, y1 float64) *geom.Polygons {
	var g geom.Polygons
	g.Add(geom.Point{X: x0, Y: y0})
	g.Add(geom.Point{X: x1, Y: y0})
	g.Add(geom.Point{X: x1, Y: y1})
	g.Add(geom.Point{X: x0, Y: y1})
	g.End()
	return &g
}

func alpha(c *Canvas, x, y int) float64 { return c.Pix[4*(y*c.W+x)+3] }

func TestFractionalCoverage(t *testing.T) {
	c := NewCanvas(8, 4)
	r := NewRasterizer(8)
	r.Fill(c, rectPolys(1, 1, 4.5, 3), NonZero, 0, 0, 1, 1)
	want := []float64{0, 1, 1, 1, .5, 0, 0, 0}
	for x, w := range want {
		if a := alpha(c, x, 1); math.Abs(a-w) > 1e-12 {
			t.Errorf("pixel %d alpha %g, want %g", x, a, w)
		}
	}
	if alpha(c, 2, 0) != 0 || alpha(c, 2, 3) != 0 {
		t.Error("rows outside the rectangle painted")
	}
	// The worked example of SPEC 10.1: pixel (4,1) becomes 0x80 0x80 0xff.
	rgb := c.RGB()
	i := 3 * (1*8 + 4)
	if rgb[i] != 0x80 || rgb[i+1] != 0x80 || rgb[i+2] != 0xff {
		t.Errorf("pixel bytes % x", rgb[i:i+3])
	}
}

func TestVerticalFractionalCoverage(t *testing.T) {
	c := NewCanvas(4, 4)
	NewRasterizer(4).Fill(c, rectPolys(0, 0.25, 4, 1.5), NonZero, 0, 0, 0, 1)
	if a := alpha(c, 1, 0); math.Abs(a-.75) > 1e-12 {
		t.Errorf("row 0 alpha %g", a)
	}
	if a := alpha(c, 1, 1); math.Abs(a-.5) > 1e-12 {
		t.Errorf("row 1 alpha %g", a)
	}
}

func TestEvenOddVsNonZero(t *testing.T) {
	var g geom.Polygons
	for _, r := range [][4]float64{{0, 0, 8, 8}, {2, 2, 6, 6}} { // same orientation
		g.Add(geom.Point{X: r[0], Y: r[1]})
		g.Add(geom.Point{X: r[2], Y: r[1]})
		g.Add(geom.Point{X: r[2], Y: r[3]})
		g.Add(geom.Point{X: r[0], Y: r[3]})
		g.End()
	}
	for rule, want := range map[Rule]float64{NonZero: 1, EvenOdd: 0} {
		c := NewCanvas(8, 8)
		NewRasterizer(8).Fill(c, &g, rule, 0, 0, 0, 1)
		if a := alpha(c, 4, 4); a != want {
			t.Errorf("rule %d centre alpha %g, want %g", rule, a, want)
		}
		if alpha(c, 0, 0) != 1 {
			t.Errorf("rule %d: corner not painted", rule)
		}
	}
}

func TestClippingAndOffCanvas(t *testing.T) {
	c := NewCanvas(4, 4)
	r := NewRasterizer(4)
	r.Fill(c, rectPolys(-100, -100, 100, 100), NonZero, 1, 0, 0, 1)
	for y := 0; y < 4; y++ {
		for x := 0; x < 4; x++ {
			if alpha(c, x, y) != 1 {
				t.Fatalf("pixel %d,%d not covered", x, y)
			}
		}
	}
	c2 := NewCanvas(4, 4)
	r.Fill(c2, rectPolys(10, 10, 20, 20), NonZero, 1, 0, 0, 1)
	r.Fill(c2, rectPolys(-5, -5, -1, -1), NonZero, 1, 0, 0, 1)
	for _, v := range c2.Pix {
		if v != 0 {
			t.Fatal("off-canvas shape painted")
		}
	}
}

func TestSourceOver(t *testing.T) {
	c := NewCanvas(2, 1)
	r := NewRasterizer(2)
	r.Fill(c, rectPolys(0, 0, 2, 1), NonZero, 1, 0, 0, .5)
	r.Fill(c, rectPolys(0, 0, 2, 1), NonZero, 0, 0, 1, .5)
	want := []float64{.25, 0, .5, .75}
	for i, w := range want {
		if math.Abs(c.Pix[i]-w) > 1e-12 {
			t.Errorf("channel %d = %g, want %g", i, c.Pix[i], w)
		}
	}
}

func TestLayerComposite(t *testing.T) {
	dst := NewCanvas(2, 2)
	layer := NewCanvas(2, 2)
	NewRasterizer(2).Fill(layer, rectPolys(0, 0, 2, 1), NonZero, 1, 0, 0, 1)
	dst.CompositeLayer(layer, .5)
	if dst.Pix[0] != .5 || dst.Pix[3] != .5 {
		t.Errorf("composite %v", dst.Pix[:4])
	}
	if dst.Pix[4*2] != 0 {
		t.Error("untouched row changed")
	}
	layer.Clear()
	for _, v := range layer.Pix {
		if v != 0 {
			t.Fatal("Clear left data behind")
		}
	}
}

func TestPPM(t *testing.T) {
	c := NewCanvas(2, 1)
	out := c.PPM()
	want := append([]byte("P6\n2 1\n255\n"), 255, 255, 255, 255, 255, 255)
	if !bytes.Equal(out, want) {
		t.Errorf("got %q", out)
	}
}
