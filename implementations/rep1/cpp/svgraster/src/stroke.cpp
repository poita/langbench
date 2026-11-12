#include "svgraster/stroke.hpp"

#include <algorithm>
#include <cmath>

namespace svgraster {

namespace {

class Builder {
public:
    Builder(const StrokeStyle& st, const Matrix& ctm) : st_(st), ctm_(ctm), r_(st.width / 2) {
        double dev_r = r_ * ctm.max_scale();
        const double tol = 0.01;
        max_step_ = dev_r > tol ? 2 * std::acos(1 - tol / dev_r) : M_PI;
        if (!(max_step_ > 1e-4)) max_step_ = 1e-4;
    }

    void add_polyline(const Polyline& pl) {
        // Drop repeated points.
        Polygon pts;
        for (const Point& p : pl.pts) {
            if (pts.empty() || !(p == pts.back())) pts.push_back(p);
        }
        if (pl.closed && pts.size() > 1 && pts.back() == pts.front()) pts.pop_back();
        const size_t n = pts.size();
        if (n == 0) return;
        if (n == 1) {
            add_point(pts[0]);
            return;
        }
        const size_t nseg = pl.closed ? n : n - 1;
        std::vector<Point> dir(nseg);
        for (size_t i = 0; i < nseg; ++i) {
            Point d = pts[(i + 1) % n] - pts[i];
            dir[i] = d * (1.0 / length(d));
            Point nrm{-dir[i].y * r_, dir[i].x * r_};
            Point a = pts[i], b = pts[(i + 1) % n];
            emit({a + nrm, b + nrm, b - nrm, a - nrm});
        }
        if (pl.closed) {
            for (size_t i = 0; i < n; ++i) join(pts[i], dir[(i + n - 1) % n], dir[i]);
        } else {
            for (size_t i = 1; i + 1 < n; ++i) join(pts[i], dir[i - 1], dir[i]);
            cap(pts[0], dir[0] * -1.0);
            cap(pts[n - 1], dir[nseg - 1]);
        }
    }

    std::vector<Polygon> take() { return std::move(out_); }

private:
    void emit(Polygon poly) {
        double area = 0;
        for (Point& p : poly) p = ctm_.apply(p);
        for (size_t i = 0; i < poly.size(); ++i) area += cross(poly[i], poly[(i + 1) % poly.size()]);
        if (area == 0) return;
        if (area < 0) std::reverse(poly.begin(), poly.end());
        out_.push_back(std::move(poly));
    }

    // Appends the points of an arc about `c` starting at vector `from`,
    // sweeping by `sweep` radians (inclusive of both ends).
    void arc(Polygon& poly, Point c, Point from, double sweep) {
        int n = std::max(1, static_cast<int>(std::ceil(std::fabs(sweep) / max_step_)));
        for (int i = 0; i <= n; ++i) {
            double a = sweep * i / n, co = std::cos(a), si = std::sin(a);
            poly.push_back(c + Point{from.x * co - from.y * si, from.x * si + from.y * co});
        }
    }

    void add_point(Point p) {
        switch (st_.cap) {
            case LineCap::Butt: break;
            case LineCap::Round: {
                Polygon poly;
                int n = std::max(3, static_cast<int>(std::ceil(2 * M_PI / max_step_)));
                for (int i = 0; i < n; ++i) {
                    double a = 2 * M_PI * i / n;
                    poly.push_back({p.x + r_ * std::cos(a), p.y + r_ * std::sin(a)});
                }
                emit(std::move(poly));
                break;
            }
            case LineCap::Square:
                emit({{p.x - r_, p.y - r_}, {p.x + r_, p.y - r_}, {p.x + r_, p.y + r_}, {p.x - r_, p.y + r_}});
                break;
        }
    }

    void join(Point p, Point d0, Point d1) {
        const double cr = cross(d0, d1), dt = dot(d0, d1);
        if (cr == 0 && dt > 0) return;
        const double s = cr > 0 ? 1 : -1;
        const Point na{s * d0.y * r_, -s * d0.x * r_}, nb{s * d1.y * r_, -s * d1.x * r_};
        const Point A = p + na, B = p + nb;
        if (st_.join == LineJoin::Round) {
            double sweep = cr == 0 ? s * M_PI : std::atan2(cross(na, nb), dot(na, nb));
            Polygon poly{p};
            arc(poly, p, na, sweep);
            emit(std::move(poly));
            return;
        }
        if (st_.join == LineJoin::Miter && dt > -1 && cr != 0) {
            double ratio = 1 / std::sqrt((1 + dt) / 2);
            if (ratio <= std::max(1.0, st_.miter_limit)) {
                Point M = p + (na + nb) * (1.0 / (1 + dt));
                emit({p, A, M, B});
                return;
            }
        }
        emit({p, A, B});
    }

    void cap(Point p, Point u) {
        if (st_.cap == LineCap::Butt) return;
        Point nrm{-u.y * r_, u.x * r_};
        if (st_.cap == LineCap::Square) {
            Point ext = u * r_;
            emit({p + nrm, p + nrm + ext, p - nrm + ext, p - nrm});
        } else {
            Polygon poly;
            arc(poly, p, nrm, -M_PI);
            emit(std::move(poly));
        }
    }

    StrokeStyle st_;
    Matrix ctm_;
    double r_;
    double max_step_;
    std::vector<Polygon> out_;
};

}  // namespace

std::vector<Polygon> stroke_polygons(const std::vector<Polyline>& centerline, const StrokeStyle& style,
                                     const Matrix& ctm) {
    Builder b(style, ctm);
    for (const Polyline& pl : centerline) b.add_polyline(pl);
    return b.take();
}

}  // namespace svgraster
