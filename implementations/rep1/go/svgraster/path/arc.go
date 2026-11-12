package path

import (
	"math"

	"svgraster/geom"
)

func arcTo(p *Path, cur geom.Point, rx, ry, rotDeg float64, large, sweep bool, end geom.Point) {
	if cur == end {
		return
	}
	rx, ry = math.Abs(rx), math.Abs(ry)
	if rx == 0 || ry == 0 {
		p.LineTo(end)
		return
	}
	phi := rotDeg * math.Pi / 180
	sinPhi, cosPhi := math.Sincos(phi)

	// F.6.5.1
	dx2, dy2 := (cur.X-end.X)/2, (cur.Y-end.Y)/2
	x1p := cosPhi*dx2 + sinPhi*dy2
	y1p := -sinPhi*dx2 + cosPhi*dy2

	// F.6.6.2: scale up radii that are too small.
	if l := x1p*x1p/(rx*rx) + y1p*y1p/(ry*ry); l > 1 {
		s := math.Sqrt(l)
		rx *= s
		ry *= s
	}

	// F.6.5.2
	num := rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
	den := rx*rx*y1p*y1p + ry*ry*x1p*x1p
	coef := 0.0
	if den != 0 {
		coef = math.Sqrt(math.Max(0, num/den))
	}
	if large == sweep {
		coef = -coef
	}
	cxp := coef * rx * y1p / ry
	cyp := -coef * ry * x1p / rx

	// F.6.5.3
	cx := cosPhi*cxp - sinPhi*cyp + (cur.X+end.X)/2
	cy := sinPhi*cxp + cosPhi*cyp + (cur.Y+end.Y)/2

	// F.6.5.5-6
	theta1 := math.Atan2((y1p-cyp)/ry, (x1p-cxp)/rx)
	theta2 := math.Atan2((-y1p-cyp)/ry, (-x1p-cxp)/rx)
	dtheta := theta2 - theta1
	if sweep && dtheta < 0 {
		dtheta += 2 * math.Pi
	} else if !sweep && dtheta > 0 {
		dtheta -= 2 * math.Pi
	}

	n := int(math.Ceil(math.Abs(dtheta) / (math.Pi / 4)))
	if n < 1 {
		n = 1
	}
	delta := dtheta / float64(n)
	k := 4.0 / 3.0 * math.Tan(delta/4)

	pos := func(t float64) geom.Point {
		s, c := math.Sincos(t)
		x, y := rx*c, ry*s
		return geom.Point{X: cx + cosPhi*x - sinPhi*y, Y: cy + sinPhi*x + cosPhi*y}
	}
	deriv := func(t float64) geom.Point {
		s, c := math.Sincos(t)
		x, y := -rx*s, ry*c
		return geom.Point{X: cosPhi*x - sinPhi*y, Y: sinPhi*x + cosPhi*y}
	}
	for i := 0; i < n; i++ {
		t0 := theta1 + float64(i)*delta
		t1 := t0 + delta
		p3 := pos(t1)
		if i == n-1 {
			p3 = end
		}
		c1 := pos(t0).Add(deriv(t0).Scale(k))
		c2 := pos(t1).Sub(deriv(t1).Scale(k))
		p.CubicTo(c1, c2, p3)
	}
}
