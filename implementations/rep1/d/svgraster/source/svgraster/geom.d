/// Basic 2-D geometry: points and affine matrices.
module svgraster.geom;

import std.math : sqrt, abs;

/// A point (or vector) in the plane.
struct Point
{
    double x = 0;
    double y = 0;

    Point opBinary(string op)(Point o) const
        if (op == "+" || op == "-")
    {
        return Point(mixin("x " ~ op ~ " o.x"), mixin("y " ~ op ~ " o.y"));
    }

    Point opBinary(string op : "*")(double k) const
    {
        return Point(x * k, y * k);
    }

    /// Dot product.
    double dot(Point o) const { return x * o.x + y * o.y; }
    /// Z component of the 3-D cross product.
    double cross(Point o) const { return x * o.y - y * o.x; }
    /// Euclidean length.
    double length() const { return sqrt(x * x + y * y); }
}

/// Linear interpolation between two points.
Point lerp(Point a, Point b, double t)
{
    return Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
}

/// An affine transform `[a c e; b d f]` (the SVG matrix layout).
struct Matrix
{
    double a = 1, b = 0, c = 0, d = 1, e = 0, f = 0;

    /// The identity transform.
    static Matrix identity() { return Matrix.init; }

    /// Translation by `(tx, ty)`.
    static Matrix translation(double tx, double ty)
    {
        return Matrix(1, 0, 0, 1, tx, ty);
    }

    /// Scale by `(sx, sy)`.
    static Matrix scaling(double sx, double sy)
    {
        return Matrix(sx, 0, 0, sy, 0, 0);
    }

    /// Matrix product `this * o`: `o` is applied to coordinates first.
    Matrix opBinary(string op : "*")(const Matrix o) const
    {
        return Matrix(
            a * o.a + c * o.b,
            b * o.a + d * o.b,
            a * o.c + c * o.d,
            b * o.c + d * o.d,
            a * o.e + c * o.f + e,
            b * o.e + d * o.f + f);
    }

    /// Transform a point.
    Point apply(Point p) const
    {
        return Point(a * p.x + c * p.y + e, b * p.x + d * p.y + f);
    }

    /// Determinant of the linear part.
    double determinant() const { return a * d - b * c; }

    /// The largest factor by which this transform stretches any vector
    /// (the largest singular value of the linear part).
    double maxScale() const
    {
        immutable p = a * a + b * b;
        immutable q = c * c + d * d;
        immutable r = a * c + b * d;
        immutable disc = sqrt((p - q) * (p - q) + 4 * r * r);
        return sqrt(abs((p + q + disc) / 2));
    }
}

unittest
{
    import std.math : isClose;

    immutable m = Matrix.translation(3, 4) * Matrix.scaling(2, 2);
    immutable p = m.apply(Point(1, 1));
    assert(isClose(p.x, 5) && isClose(p.y, 6));
    assert(isClose(Matrix.scaling(3, 2).maxScale, 3));
    assert(isClose(Matrix.scaling(3, -2).determinant, -6));
}
