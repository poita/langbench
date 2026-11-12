package geom

import (
	"math"
	"testing"
)

func TestMulOrder(t *testing.T) {
	m := Translate(10, 0).Mul(ScaleM(2, 2)) // scale applies first
	if p := m.Apply(Point{X: 1, Y: 1}); p != (Point{X: 12, Y: 2}) {
		t.Errorf("got %v", p)
	}
}

func TestRotate(t *testing.T) {
	p := Rotate(90).Apply(Point{X: 1, Y: 0})
	if math.Abs(p.X) > 1e-12 || math.Abs(p.Y-1) > 1e-12 {
		t.Errorf("rotate(90) of +x = %v, want +y", p)
	}
}

func TestMaxScale(t *testing.T) {
	for _, tc := range []struct {
		m    Matrix
		want float64
	}{
		{ScaleM(2, 3), 3}, {Rotate(33), 1}, {ScaleM(0, 0), 0}, {Matrix{A: 1, C: 1, D: 1}, (1 + math.Sqrt(5)) / 2},
	} {
		if got := tc.m.MaxScale(); math.Abs(got-tc.want) > 1e-9 {
			t.Errorf("MaxScale(%+v) = %v, want %v", tc.m, got, tc.want)
		}
	}
}
