//! Basic geometry: points and 2-D affine matrices.

/// A point (or vector) in the plane.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Point {
    /// Horizontal coordinate.
    pub x: f64,
    /// Vertical coordinate.
    pub y: f64,
}

impl Point {
    /// Creates a point.
    pub const fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }
}

/// An affine transform `[a c e; b d f]` mapping `(x, y)` to
/// `(a*x + c*y + e, b*x + d*y + f)`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Matrix {
    /// x scale / rotation term.
    pub a: f64,
    /// y shear term.
    pub b: f64,
    /// x shear term.
    pub c: f64,
    /// y scale / rotation term.
    pub d: f64,
    /// x translation.
    pub e: f64,
    /// y translation.
    pub f: f64,
}

impl Matrix {
    /// The identity transform.
    pub const IDENTITY: Matrix = Matrix { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 };

    /// A translation.
    pub fn translate(tx: f64, ty: f64) -> Self {
        Matrix { e: tx, f: ty, ..Self::IDENTITY }
    }

    /// A scale about the origin.
    pub fn scale(sx: f64, sy: f64) -> Self {
        Matrix { a: sx, d: sy, ..Self::IDENTITY }
    }

    /// A rotation about the origin by `deg` degrees (clockwise on screen).
    pub fn rotate(deg: f64) -> Self {
        let (s, c) = deg.to_radians().sin_cos();
        Matrix { a: c, b: s, c: -s, d: c, e: 0.0, f: 0.0 }
    }

    /// Returns `self * other`: `other` is applied to coordinates first.
    pub fn mul(&self, o: &Matrix) -> Matrix {
        Matrix {
            a: self.a * o.a + self.c * o.b,
            b: self.b * o.a + self.d * o.b,
            c: self.a * o.c + self.c * o.d,
            d: self.b * o.c + self.d * o.d,
            e: self.a * o.e + self.c * o.f + self.e,
            f: self.b * o.e + self.d * o.f + self.f,
        }
    }

    /// Transforms a point.
    pub fn apply(&self, p: Point) -> Point {
        Point::new(self.a * p.x + self.c * p.y + self.e, self.b * p.x + self.d * p.y + self.f)
    }

    /// Determinant of the linear part.
    pub fn det(&self) -> f64 {
        self.a * self.d - self.b * self.c
    }

    /// The largest factor by which the linear part stretches any vector
    /// (its largest singular value).
    pub fn max_scale(&self) -> f64 {
        let s = self.a * self.a + self.b * self.b + self.c * self.c + self.d * self.d;
        let det = self.det();
        let disc = (s * s - 4.0 * det * det).max(0.0).sqrt();
        ((s + disc) / 2.0).sqrt()
    }
}

impl Default for Matrix {
    fn default() -> Self {
        Self::IDENTITY
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mul_applies_right_operand_first() {
        let m = Matrix::translate(10.0, 0.0).mul(&Matrix::scale(2.0, 2.0));
        let p = m.apply(Point::new(1.0, 1.0));
        assert_eq!(p, Point::new(12.0, 2.0));
    }

    #[test]
    fn max_scale_of_uniform_scale() {
        assert!((Matrix::scale(3.0, 3.0).max_scale() - 3.0).abs() < 1e-12);
        assert!((Matrix::scale(3.0, 5.0).max_scale() - 5.0).abs() < 1e-12);
    }

    #[test]
    fn rotate_quarter_turn_is_clockwise_on_screen() {
        let p = Matrix::rotate(90.0).apply(Point::new(1.0, 0.0));
        assert!((p.x).abs() < 1e-12 && (p.y - 1.0).abs() < 1e-12);
    }
}
