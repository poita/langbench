// Package geom provides the small geometric types shared by the other
// svgraster packages: points, 2D affine matrices and flat polygon buffers.
package geom

import "math"

// Point is a position (or vector) in a 2D coordinate system.
type Point struct{ X, Y float64 }

// Add returns p+q.
func (p Point) Add(q Point) Point { return Point{p.X + q.X, p.Y + q.Y} }

// Sub returns p-q.
func (p Point) Sub(q Point) Point { return Point{p.X - q.X, p.Y - q.Y} }

// Scale returns p scaled by k.
func (p Point) Scale(k float64) Point { return Point{p.X * k, p.Y * k} }

// Dot returns the dot product p.q.
func (p Point) Dot(q Point) float64 { return p.X*q.X + p.Y*q.Y }

// Cross returns the z component of the cross product p x q.
func (p Point) Cross(q Point) float64 { return p.X*q.Y - p.Y*q.X }

// Len returns the Euclidean length of p.
func (p Point) Len() float64 { return math.Hypot(p.X, p.Y) }

// Matrix is a 2D affine transform in SVG's [a c e; b d f] layout:
//
//	x' = A*x + C*y + E
//	y' = B*x + D*y + F
type Matrix struct{ A, B, C, D, E, F float64 }

// Identity is the identity transform.
var Identity = Matrix{A: 1, D: 1}

// Translate returns a translation by (tx, ty).
func Translate(tx, ty float64) Matrix { return Matrix{1, 0, 0, 1, tx, ty} }

// Scale returns a scaling by (sx, sy).
func Scale(sx, sy float64) Matrix { return Matrix{sx, 0, 0, sy, 0, 0} }

// Rotate returns a rotation by deg degrees about the origin (clockwise on a
// y-down screen).
func Rotate(deg float64) Matrix {
	s, c := math.Sincos(deg * math.Pi / 180)
	return Matrix{c, s, -s, c, 0, 0}
}

// Mul returns m*n: the transform that applies n first and then m.
func (m Matrix) Mul(n Matrix) Matrix {
	return Matrix{
		A: m.A*n.A + m.C*n.B,
		B: m.B*n.A + m.D*n.B,
		C: m.A*n.C + m.C*n.D,
		D: m.B*n.C + m.D*n.D,
		E: m.A*n.E + m.C*n.F + m.E,
		F: m.B*n.E + m.D*n.F + m.F,
	}
}

// Apply transforms the point p.
func (m Matrix) Apply(p Point) Point {
	return Point{m.A*p.X + m.C*p.Y + m.E, m.B*p.X + m.D*p.Y + m.F}
}

// MaxScale returns the length of the longer column of the linear part of m,
// a cheap bound on how much m can stretch a unit vector.
func (m Matrix) MaxScale() float64 {
	return math.Sqrt(math.Max(m.A*m.A+m.B*m.B, m.C*m.C+m.D*m.D))
}

// Polygons is a growable buffer of closed polygons stored back to back, so a
// whole stroke outline needs no per-polygon allocation. Polygon i occupies
// Pts[Ends[i-1]:Ends[i]] (Ends[-1] being 0).
type Polygons struct {
	Pts  []Point
	Ends []int
}

// Reset empties the buffer, keeping its capacity.
func (g *Polygons) Reset() { g.Pts = g.Pts[:0]; g.Ends = g.Ends[:0] }

// Len returns the number of finished polygons.
func (g *Polygons) Len() int { return len(g.Ends) }

// Poly returns the points of polygon i.
func (g *Polygons) Poly(i int) []Point {
	lo := 0
	if i > 0 {
		lo = g.Ends[i-1]
	}
	return g.Pts[lo:g.Ends[i]]
}

// Add appends a point to the polygon under construction.
func (g *Polygons) Add(p Point) { g.Pts = append(g.Pts, p) }

// End finishes the polygon under construction.
func (g *Polygons) End() { g.Ends = append(g.Ends, len(g.Pts)) }

func (g *Polygons) start() int {
	if n := len(g.Ends); n > 0 {
		return g.Ends[n-1]
	}
	return 0
}

// EndOriented finishes the polygon under construction, reversing it in place
// if needed so that its signed area (shoelace sum) is non-negative.
func (g *Polygons) EndOriented() {
	pts := g.Pts[g.start():]
	var area float64
	for i := range pts {
		j := i + 1
		if j == len(pts) {
			j = 0
		}
		area += pts[i].X*pts[j].Y - pts[j].X*pts[i].Y
	}
	if area < 0 {
		for i, j := 0, len(pts)-1; i < j; i, j = i+1, j-1 {
			pts[i], pts[j] = pts[j], pts[i]
		}
	}
	g.End()
}

// Transform maps every point through m, in place.
func (g *Polygons) Transform(m Matrix) {
	for i, p := range g.Pts {
		g.Pts[i] = m.Apply(p)
	}
}
