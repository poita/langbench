package svgpath

import (
	"math"

	"svgraster/geom"
)

// ArcTo appends an SVG elliptical arc from the current point to (x, y),
// converted to cubic segments as in SVG 1.1 implementation notes F.6.5-F.6.6.
// rot is the x-axis rotation in degrees.
func (p *Path) ArcTo(rx, ry, rot float64, large, sweep bool, x, y float64) {
	if !p.haveMove {
		return
	}
	x1, y1 := p.cur.X, p.cur.Y
	if x1 == x && y1 == y {
		return
	}
	rx, ry = math.Abs(rx), math.Abs(ry)
	if rx == 0 || ry == 0 {
		p.LineTo(geom.Point{X: x, Y: y})
		return
	}
	sinPhi, cosPhi := math.Sincos(rot * math.Pi / 180)
	dx2, dy2 := (x1-x)/2, (y1-y)/2
	x1p := cosPhi*dx2 + sinPhi*dy2
	y1p := -sinPhi*dx2 + cosPhi*dy2
	if l := x1p*x1p/(rx*rx) + y1p*y1p/(ry*ry); l > 1 {
		s := math.Sqrt(l)
		rx *= s
		ry *= s
	}
	rx2, ry2 := rx*rx, ry*ry
	num := rx2*ry2 - rx2*y1p*y1p - ry2*x1p*x1p
	den := rx2*y1p*y1p + ry2*x1p*x1p
	coef := 0.0
	if den != 0 && num > 0 {
		coef = math.Sqrt(num / den)
	}
	if large == sweep {
		coef = -coef
	}
	cxp := coef * rx * y1p / ry
	cyp := -coef * ry * x1p / rx
	cx := cosPhi*cxp - sinPhi*cyp + (x1+x)/2
	cy := sinPhi*cxp + cosPhi*cyp + (y1+y)/2
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
	k := 4.0 / 3 * math.Tan(delta/4)
	point := func(t float64) (geom.Point, geom.Point) {
		s, c := math.Sincos(t)
		pt := geom.Point{
			X: cx + cosPhi*rx*c - sinPhi*ry*s,
			Y: cy + sinPhi*rx*c + cosPhi*ry*s,
		}
		d := geom.Point{
			X: -cosPhi*rx*s - sinPhi*ry*c,
			Y: -sinPhi*rx*s + cosPhi*ry*c,
		}
		return pt, d
	}
	end := geom.Point{X: x, Y: y}
	for i := 0; i < n; i++ {
		t0 := theta1 + float64(i)*delta
		t1 := t0 + delta
		e0, d0 := point(t0)
		e1, d1 := point(t1)
		if i == n-1 {
			e1 = end
		}
		p.CubicTo(e0.Add(d0.Scale(k)), e1.Sub(d1.Scale(k)), e1)
	}
}
