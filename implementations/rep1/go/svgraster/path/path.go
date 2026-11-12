// Package path represents vector paths, parses SVG path data, converts basic
// shapes to paths and flattens curves to polylines.
package path

import "svgraster/geom"

// Kind identifies a path segment type.
type Kind uint8

// Segment kinds. Every curve is stored as a cubic Bézier.
const (
	MoveTo  Kind = iota // start a new subpath at P[0]
	LineTo              // line to P[0]
	CubicTo             // cubic with controls P[0], P[1] and end point P[2]
	Close               // close the current subpath
)

// Segment is one path command in absolute coordinates.
type Segment struct {
	Kind Kind
	P    [3]geom.Point
}

// Path is a sequence of segments.
type Path struct {
	Segs []Segment
}

// MoveTo starts a new subpath.
func (p *Path) MoveTo(pt geom.Point) {
	p.Segs = append(p.Segs, Segment{Kind: MoveTo, P: [3]geom.Point{pt}})
}

// LineTo appends a straight line.
func (p *Path) LineTo(pt geom.Point) {
	p.Segs = append(p.Segs, Segment{Kind: LineTo, P: [3]geom.Point{pt}})
}

// CubicTo appends a cubic Bézier curve.
func (p *Path) CubicTo(c1, c2, end geom.Point) {
	p.Segs = append(p.Segs, Segment{Kind: CubicTo, P: [3]geom.Point{c1, c2, end}})
}

// Close closes the current subpath.
func (p *Path) Close() { p.Segs = append(p.Segs, Segment{Kind: Close}) }

// ArcTo appends an SVG elliptical arc from the current point cur to end as a
// series of cubic segments (SVG 1.1 implementation notes F.6.5-F.6.6). It
// does nothing if cur == end; with a zero radius it appends a straight line.
func (p *Path) ArcTo(cur geom.Point, rx, ry, rotDeg float64, large, sweep bool, end geom.Point) {
	arcTo(p, cur, rx, ry, rotDeg, large, sweep, end)
}
