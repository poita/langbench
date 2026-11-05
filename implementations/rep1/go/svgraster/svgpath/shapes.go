package svgpath

import "svgraster/geom"

// Rect returns the path of a rectangle with corner radii rx, ry. The radii
// must already be resolved (non-negative and at most half the size); a zero
// radius gives a plain rectangle. The caller must ensure w, h > 0.
func Rect(x, y, w, h, rx, ry float64) *Path {
	p := &Path{}
	pt := func(a, b float64) geom.Point { return geom.Point{X: a, Y: b} }
	if rx == 0 || ry == 0 {
		p.MoveTo(pt(x, y))
		p.LineTo(pt(x+w, y))
		p.LineTo(pt(x+w, y+h))
		p.LineTo(pt(x, y+h))
		p.Close()
		return p
	}
	p.MoveTo(pt(x+rx, y))
	p.LineTo(pt(x+w-rx, y))
	p.ArcTo(rx, ry, 0, false, true, x+w, y+ry)
	p.LineTo(pt(x+w, y+h-ry))
	p.ArcTo(rx, ry, 0, false, true, x+w-rx, y+h)
	p.LineTo(pt(x+rx, y+h))
	p.ArcTo(rx, ry, 0, false, true, x, y+h-ry)
	p.LineTo(pt(x, y+ry))
	p.ArcTo(rx, ry, 0, false, true, x+rx, y)
	p.Close()
	return p
}

// Ellipse returns the path of an ellipse; rx, ry must be positive.
func Ellipse(cx, cy, rx, ry float64) *Path {
	p := &Path{}
	p.MoveTo(geom.Point{X: cx + rx, Y: cy})
	p.ArcTo(rx, ry, 0, false, true, cx, cy+ry)
	p.ArcTo(rx, ry, 0, false, true, cx-rx, cy)
	p.ArcTo(rx, ry, 0, false, true, cx, cy-ry)
	p.ArcTo(rx, ry, 0, false, true, cx+rx, cy)
	p.Close()
	return p
}

// Line returns the path of a single line segment.
func Line(x1, y1, x2, y2 float64) *Path {
	p := &Path{}
	p.MoveTo(geom.Point{X: x1, Y: y1})
	p.LineTo(geom.Point{X: x2, Y: y2})
	return p
}

// Poly returns the path through the coordinate pairs in nums (an odd trailing
// number is dropped), closed if closed is set. It returns nil if there are no
// points.
func Poly(nums []float64, closed bool) *Path {
	n := len(nums) / 2
	if n == 0 {
		return nil
	}
	p := &Path{}
	p.MoveTo(geom.Point{X: nums[0], Y: nums[1]})
	for i := 1; i < n; i++ {
		p.LineTo(geom.Point{X: nums[2*i], Y: nums[2*i+1]})
	}
	if closed {
		p.Close()
	}
	return p
}
