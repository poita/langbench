package stroke

import (
	"math"
	"testing"

	"svgraster/geom"
	"svgraster/path"
	"svgraster/raster"
)

func sub(closed bool, pts ...geom.Point) path.Subpath {
	return path.Subpath{Points: pts, Closed: closed}
}

// area returns the total area of the outline, measured by rasterising it on a w x h grid.
func area(t *testing.T, polys [][]geom.Point, w, h int) float64 {
	t.Helper()
	c := raster.NewCanvas(w, h)
	c.FillPolygons(raster.Orient(polys), raster.NonZero, [3]float64{0, 0, 0}, 1)
	sum := 0.0
	for i := 3; i < len(c.Pix); i += 4 {
		sum += c.Pix[i]
	}
	return sum
}

func TestSegmentRectangle(t *testing.T) {
	polys := Outline([]path.Subpath{sub(false, geom.Point{X: 2, Y: 5}, geom.Point{X: 12, Y: 5})},
		Style{Width: 4, MiterLimit: 4}, 0.01)
	if a := area(t, polys, 20, 10); math.Abs(a-40) > 0.1 {
		t.Errorf("area = %v, want 40", a)
	}
}

func TestCaps(t *testing.T) {
	line := []path.Subpath{sub(false, geom.Point{X: 5, Y: 5}, geom.Point{X: 15, Y: 5})}
	want := map[Cap]float64{ButtCap: 40, SquareCap: 56, RoundCap: 40 + math.Pi*4}
	for c, w := range want {
		a := area(t, Outline(line, Style{Width: 4, Cap: c, MiterLimit: 4}, 0.01), 20, 10)
		if math.Abs(a-w) > 0.1 {
			t.Errorf("cap %d area = %v, want %v", c, a, w)
		}
	}
}

func TestPointSubpath(t *testing.T) {
	pt := []path.Subpath{sub(false, geom.Point{X: 5, Y: 5}, geom.Point{X: 5, Y: 5})}
	if p := Outline(pt, Style{Width: 4}, 0.01); len(p) != 0 {
		t.Error("butt cap point draws nothing")
	}
	if a := area(t, Outline(pt, Style{Width: 4, Cap: SquareCap}, 0.01), 10, 10); math.Abs(a-16) > 1e-6 {
		t.Errorf("square point area = %v", a)
	}
	if a := area(t, Outline(pt, Style{Width: 4, Cap: RoundCap}, 0.01), 10, 10); math.Abs(a-4*math.Pi) > 0.15 {
		t.Errorf("round point area = %v", a)
	}
}

func TestJoins(t *testing.T) {
	// A right angle with stroke width 2 on the grid; the outer corner of the
	// join is the only difference between the styles.
	corner := []path.Subpath{sub(false, geom.Point{X: 2, Y: 8}, geom.Point{X: 2, Y: 2}, geom.Point{X: 8, Y: 2})}
	base := area(t, Outline(corner, Style{Width: 2, Join: BevelJoin, MiterLimit: 4}, 0.01), 12, 12)
	miter := area(t, Outline(corner, Style{Width: 2, Join: MiterJoin, MiterLimit: 4}, 0.01), 12, 12)
	round := area(t, Outline(corner, Style{Width: 2, Join: RoundJoin, MiterLimit: 4}, 0.01), 12, 12)
	if math.Abs(miter-base-0.5) > 0.05 {
		t.Errorf("miter - bevel = %v, want 0.5", miter-base)
	}
	if want := math.Pi/4 - 0.5; math.Abs(round-base-want) > 0.05 {
		t.Errorf("round - bevel = %v, want %v", round-base, want)
	}
	if !(base < round && round < miter) {
		t.Errorf("expected bevel < round < miter, got %v %v %v", base, round, miter)
	}
	// A miter limit below the ratio (sqrt 2) falls back to a bevel.
	low := area(t, Outline(corner, Style{Width: 2, Join: MiterJoin, MiterLimit: 1.2}, 0.01), 12, 12)
	if math.Abs(low-base) > 1e-6 {
		t.Errorf("miter limit fallback = %v, want bevel %v", low, base)
	}
}

func TestClosedSubpath(t *testing.T) {
	sq := []path.Subpath{sub(true, geom.Point{X: 2, Y: 2}, geom.Point{X: 8, Y: 2},
		geom.Point{X: 8, Y: 8}, geom.Point{X: 2, Y: 8}, geom.Point{X: 2, Y: 2})}
	a := area(t, Outline(sq, Style{Width: 2, MiterLimit: 4}, 0.01), 10, 10)
	if math.Abs(a-(64-16)) > 1e-6 { // 8x8 outer minus 4x4 inner
		t.Errorf("area = %v, want 48", a)
	}
}
