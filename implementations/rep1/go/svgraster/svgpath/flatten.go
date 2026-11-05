package svgpath

import (
	"math"

	"svgraster/geom"
)

// Subpath is a flattened subpath: a polyline and whether it was closed.
type Subpath struct {
	Pts    []geom.Point
	Closed bool
}

// MaxSteps caps the number of line segments a single cubic is split into.
const MaxSteps = 1000

// Flatten transforms p by m and replaces every cubic with a polyline that
// stays within tol (in the transformed space) of the curve. Each cubic is cut
// into n equal steps in t with n = ceil(sqrt(0.75*sqrt(m)/tol)), where m is
// the larger squared second difference of the control polygon.
//
// A lone MoveTo with no drawing command after it yields no subpath. A subpath
// that has drawing commands, even one that collapses to a point, is kept.
func Flatten(p *Path, m geom.Matrix, tol float64) []Subpath {
	var out []Subpath
	var cur Subpath
	hasDraw := false
	have := false
	flush := func() {
		if have && hasDraw {
			out = append(out, cur)
		}
		cur, hasDraw, have = Subpath{}, false, false
	}
	k := 0
	for _, op := range p.Ops {
		switch op {
		case OpMove:
			flush()
			cur.Pts = append(cur.Pts, m.Apply(p.Pts[k]))
			have = true
			k++
		case OpLine:
			if have {
				cur.Pts = append(cur.Pts, m.Apply(p.Pts[k]))
				hasDraw = true
			}
			k++
		case OpCubic:
			if have {
				p0 := cur.Pts[len(cur.Pts)-1]
				cur.Pts = flattenCubic(cur.Pts, p0, m.Apply(p.Pts[k]), m.Apply(p.Pts[k+1]), m.Apply(p.Pts[k+2]), tol)
				hasDraw = true
			}
			k += 3
		case OpClose:
			if have {
				cur.Closed = true
				hasDraw = true
			}
		}
	}
	flush()
	return out
}

// flattenCubic appends the points of the cubic p0..p3 after p0 to dst.
func flattenCubic(dst []geom.Point, p0, p1, p2, p3 geom.Point, tol float64) []geom.Point {
	d1 := p0.Sub(p1.Scale(2)).Add(p2)
	d2 := p1.Sub(p2.Scale(2)).Add(p3)
	mm := math.Max(d1.Dot(d1), d2.Dot(d2))
	nf := math.Ceil(math.Sqrt(0.75 * math.Sqrt(mm) / tol))
	n := MaxSteps
	if nf < MaxSteps { // false for NaN as well
		n = 1
		if nf > 1 {
			n = int(nf)
		}
	}
	if mm != mm {
		n = 1
	}
	for i := 1; i < n; i++ {
		t := float64(i) / float64(n)
		u := 1 - t
		a, b, c, d := u*u*u, 3*u*u*t, 3*u*t*t, t*t*t
		dst = append(dst, geom.Point{
			X: a*p0.X + b*p1.X + c*p2.X + d*p3.X,
			Y: a*p0.Y + b*p1.Y + c*p2.Y + d*p3.Y,
		})
	}
	return append(dst, p3)
}
