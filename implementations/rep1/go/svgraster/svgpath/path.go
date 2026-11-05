// Package svgpath models SVG geometry: a path of move/line/cubic/close
// segments, the path-data and basic-shape producers, elliptical arc
// conversion and cubic flattening.
package svgpath

import "svgraster/geom"

// Op is a path segment kind.
type Op uint8

const (
	// OpMove starts a subpath (1 point).
	OpMove Op = iota
	// OpLine draws a line to a point (1 point).
	OpLine
	// OpCubic draws a cubic Bézier (3 points: two controls and the end).
	OpCubic
	// OpClose closes the current subpath (no points).
	OpClose
)

// Path is a sequence of segments in some coordinate system. Points holds the
// operands of the segments in order.
type Path struct {
	Ops []Op
	Pts []geom.Point

	cur, start geom.Point
	haveMove   bool // a MoveTo has been seen
	open       bool // the current subpath has not been closed
}

// Current returns the current point.
func (p *Path) Current() geom.Point { return p.cur }

// MoveTo starts a new subpath.
func (p *Path) MoveTo(pt geom.Point) {
	p.Ops = append(p.Ops, OpMove)
	p.Pts = append(p.Pts, pt)
	p.cur, p.start = pt, pt
	p.haveMove, p.open = true, true
}

// ensure starts a new subpath at the last start point after a Close.
func (p *Path) ensure() bool {
	if !p.haveMove {
		return false
	}
	if !p.open {
		p.MoveTo(p.start)
	}
	return true
}

// LineTo draws a straight line to pt.
func (p *Path) LineTo(pt geom.Point) {
	if !p.ensure() {
		return
	}
	p.Ops = append(p.Ops, OpLine)
	p.Pts = append(p.Pts, pt)
	p.cur = pt
}

// CubicTo draws a cubic Bézier with controls c1, c2 ending at e.
func (p *Path) CubicTo(c1, c2, e geom.Point) {
	if !p.ensure() {
		return
	}
	p.Ops = append(p.Ops, OpCubic)
	p.Pts = append(p.Pts, c1, c2, e)
	p.cur = e
}

// QuadTo draws a quadratic Bézier, converted exactly to a cubic.
func (p *Path) QuadTo(q, e geom.Point) {
	c := p.cur
	p.CubicTo(c.Add(q.Sub(c).Scale(2.0/3)), e.Add(q.Sub(e).Scale(2.0/3)), e)
}

// Close closes the current subpath. It does nothing before the first MoveTo
// or when the subpath is already closed.
func (p *Path) Close() {
	if !p.haveMove || !p.open {
		return
	}
	p.Ops = append(p.Ops, OpClose)
	p.cur = p.start
	p.open = false
}
