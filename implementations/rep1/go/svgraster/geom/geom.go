// Package geom provides the small amount of 2-D geometry the rasteriser
// needs: points and affine matrices.
package geom

import "math"

// Point is a position (or vector) in the plane.
type Point struct{ X, Y float64 }

// Add returns p+q.
func (p Point) Add(q Point) Point { return Point{p.X + q.X, p.Y + q.Y} }

// Sub returns p-q.
func (p Point) Sub(q Point) Point { return Point{p.X - q.X, p.Y - q.Y} }

// Scale returns p multiplied by s.
func (p Point) Scale(s float64) Point { return Point{p.X * s, p.Y * s} }

// Dot returns the dot product p·q.
func (p Point) Dot(q Point) float64 { return p.X*q.X + p.Y*q.Y }

// Cross returns the z component of the cross product p×q.
func (p Point) Cross(q Point) float64 { return p.X*q.Y - p.Y*q.X }

// Len returns the Euclidean length of p.
func (p Point) Len() float64 { return math.Hypot(p.X, p.Y) }

// Finite reports whether both coordinates are finite numbers.
func (p Point) Finite() bool {
	return !math.IsNaN(p.X) && !math.IsInf(p.X, 0) && !math.IsNaN(p.Y) && !math.IsInf(p.Y, 0)
}

// Matrix is the affine transform
//
//	[ A C E ]
//	[ B D F ]
//
// mapping (x, y) to (A*x + C*y + E, B*x + D*y + F), as in SVG.
type Matrix struct{ A, B, C, D, E, F float64 }

// Identity is the identity transform.
var Identity = Matrix{1, 0, 0, 1, 0, 0}

// Translate returns a translation matrix.
func Translate(tx, ty float64) Matrix { return Matrix{1, 0, 0, 1, tx, ty} }

// ScaleM returns a scaling matrix.
func ScaleM(sx, sy float64) Matrix { return Matrix{sx, 0, 0, sy, 0, 0} }

// Rotate returns a rotation by deg degrees (clockwise on a y-down screen).
func Rotate(deg float64) Matrix {
	r := deg * math.Pi / 180
	s, c := math.Sincos(r)
	return Matrix{c, s, -s, c, 0, 0}
}

// SkewX returns a horizontal skew by deg degrees.
func SkewX(deg float64) Matrix { return Matrix{1, 0, math.Tan(deg * math.Pi / 180), 1, 0, 0} }

// SkewY returns a vertical skew by deg degrees.
func SkewY(deg float64) Matrix { return Matrix{1, math.Tan(deg * math.Pi / 180), 0, 1, 0, 0} }

// Mul returns the matrix product m*n: n is applied to coordinates first.
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

// MaxScale returns the largest factor by which m stretches any vector (its
// largest singular value).
func (m Matrix) MaxScale() float64 {
	// Singular values of [A C; B D]: sqrt of eigenvalues of M^T M.
	p := m.A*m.A + m.B*m.B
	q := m.C*m.C + m.D*m.D
	r := m.A*m.C + m.B*m.D
	tr := p + q
	disc := math.Sqrt(math.Max(0, (p-q)*(p-q)+4*r*r))
	return math.Sqrt(math.Max(0, (tr+disc)/2))
}
