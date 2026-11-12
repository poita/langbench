// Basic 2D geometry types: points and affine matrices.
#pragma once

#include <cmath>
#include <vector>

namespace svgraster {

struct Point {
    double x = 0, y = 0;
};

inline Point operator+(Point a, Point b) { return {a.x + b.x, a.y + b.y}; }
inline Point operator-(Point a, Point b) { return {a.x - b.x, a.y - b.y}; }
inline Point operator*(Point a, double s) { return {a.x * s, a.y * s}; }
inline bool operator==(Point a, Point b) { return a.x == b.x && a.y == b.y; }
inline double dot(Point a, Point b) { return a.x * b.x + a.y * b.y; }
inline double cross(Point a, Point b) { return a.x * b.y - a.y * b.x; }
inline double length(Point a) { return std::hypot(a.x, a.y); }

/// Affine transform [a c e; b d f] mapping (x, y) to (a x + c y + e, b x + d y + f).
struct Matrix {
    double a = 1, b = 0, c = 0, d = 1, e = 0, f = 0;

    static Matrix translate(double tx, double ty) { return {1, 0, 0, 1, tx, ty}; }
    static Matrix scale(double sx, double sy) { return {sx, 0, 0, sy, 0, 0}; }

    Point apply(Point p) const { return {a * p.x + c * p.y + e, b * p.x + d * p.y + f}; }

    /// Matrix product `*this * o`: `o` is applied to coordinates first.
    Matrix operator*(const Matrix& o) const {
        return {a * o.a + c * o.b,       b * o.a + d * o.b,
                a * o.c + c * o.d,       b * o.c + d * o.d,
                a * o.e + c * o.f + e,   b * o.e + d * o.f + f};
    }

    double determinant() const { return a * d - b * c; }

    /// Largest factor by which the matrix stretches any vector.
    double max_scale() const {
        double p = a * a + b * b + c * c + d * d;
        double q = determinant();
        double disc = std::sqrt(std::fmax(0.0, p * p - 4 * q * q));
        return std::sqrt(std::fmax(0.0, (p + disc) / 2));
    }
};

using Polygon = std::vector<Point>;

}  // namespace svgraster
