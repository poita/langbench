/// Basic geometry: points and 2x3 affine matrices.
module svgraster.geom;

import std.math : cos, sin, tan, sqrt, PI;
import std.algorithm.comparison : max;

/// A point or vector in the plane.
struct Vec2
{
    double x = 0;
    double y = 0;
}

/// An affine transform `[a c e; b d f]` mapping `(x, y)` to
/// `(a*x + c*y + e, b*x + d*y + f)`.
struct Matrix
{
    double a = 1, b = 0, c = 0, d = 1, e = 0, f = 0;

    /// Composition: `(m * n).apply(p) == m.apply(n.apply(p))`.
    Matrix opBinary(string op : "*")(const Matrix o) const pure nothrow @nogc @safe
    {
        return Matrix(
            a * o.a + c * o.b, b * o.a + d * o.b,
            a * o.c + c * o.d, b * o.c + d * o.d,
            a * o.e + c * o.f + e, b * o.e + d * o.f + f);
    }

    /// Transform a point.
    Vec2 apply(const Vec2 p) const pure nothrow @nogc @safe
    {
        return Vec2(a * p.x + c * p.y + e, b * p.x + d * p.y + f);
    }

    /// The larger of the two column lengths: how much the matrix can scale a
    /// unit vector along an axis.
    double maxScale() const pure nothrow @nogc @safe
    {
        return sqrt(max(a * a + b * b, c * c + d * d));
    }

    /// Translation by `(tx, ty)`.
    static Matrix translate(double tx, double ty) pure nothrow @nogc @safe
    {
        return Matrix(1, 0, 0, 1, tx, ty);
    }

    /// Scale by `(sx, sy)`.
    static Matrix scale(double sx, double sy) pure nothrow @nogc @safe
    {
        return Matrix(sx, 0, 0, sy, 0, 0);
    }

    /// Rotation by `deg` degrees (positive turns +x towards +y).
    static Matrix rotate(double deg) @trusted pure nothrow @nogc
    {
        immutable r = deg * PI / 180.0;
        immutable cs = cos(r), sn = sin(r);
        return Matrix(cs, sn, -sn, cs, 0, 0);
    }

    /// Skew along x by `deg` degrees.
    static Matrix skewX(double deg) @trusted pure nothrow @nogc
    {
        return Matrix(1, 0, tan(deg * PI / 180.0), 1, 0, 0);
    }

    /// Skew along y by `deg` degrees.
    static Matrix skewY(double deg) @trusted pure nothrow @nogc
    {
        return Matrix(1, tan(deg * PI / 180.0), 0, 1, 0, 0);
    }
}
