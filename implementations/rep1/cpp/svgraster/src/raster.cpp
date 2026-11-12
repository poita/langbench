#include "svgraster/raster.hpp"

#include <algorithm>
#include <cmath>

namespace svgraster {

constexpr int kSubScanlines = 64;

// ---------------------------------------------------------------- Canvas

Canvas::Canvas(int width, int height)
    : w_(width), h_(height), px_(static_cast<size_t>(width) * height * 4, 0.0), dirty_lo_(height), dirty_hi_(0) {}

void Canvas::mark_dirty(int b, int e) {
    dirty_lo_ = std::min(dirty_lo_, b);
    dirty_hi_ = std::max(dirty_hi_, e);
}

void Canvas::composite_layer(const Canvas& layer, double o) {
    int b = layer.dirty_lo_, e = layer.dirty_hi_;
    for (int y = b; y < e; ++y) {
        const double* s = layer.pixel(0, y);
        double* d = pixel(0, y);
        for (int x = 0; x < w_; ++x, s += 4, d += 4) {
            if (s[3] == 0) continue;
            double inv = 1 - s[3] * o;
            for (int c = 0; c < 4; ++c) d[c] = s[c] * o + d[c] * inv;
        }
    }
    if (b < e) mark_dirty(b, e);
}

std::vector<uint8_t> Canvas::to_rgb8() const {
    std::vector<uint8_t> out(static_cast<size_t>(w_) * h_ * 3);
    const double* p = px_.data();
    uint8_t* o = out.data();
    for (size_t i = 0, n = static_cast<size_t>(w_) * h_; i < n; ++i, p += 4, o += 3) {
        for (int c = 0; c < 3; ++c) {
            double v = std::clamp(p[c] + (1 - p[3]), 0.0, 1.0);
            o[c] = static_cast<uint8_t>(std::floor(v * 255 + 0.5));
        }
    }
    return out;
}

std::string encode_ppm(const Canvas& canvas) {
    std::string out = "P6\n" + std::to_string(canvas.width()) + " " + std::to_string(canvas.height()) + "\n255\n";
    std::vector<uint8_t> rgb = canvas.to_rgb8();
    out.append(reinterpret_cast<const char*>(rgb.data()), rgb.size());
    return out;
}

// ---------------------------------------------------------------- filler

namespace {

struct Edge {
    double x0, y0, slope;  // x = x0 + (y - y0) * slope, with y0 < y1
    long k0, k1;           // first and last sub-scanline (inclusive) the edge crosses
    int dir;               // +1 when the original edge points down
};

struct Active {
    double x;
    int dir;
    long k1;
    const Edge* e;
};

// Accumulates span coverage for one pixel row and composites it.
class RowAccumulator {
public:
    explicit RowAccumulator(int w) : w_(w), cov_(w + 2, 0.0), delta_(w + 2, 0.0), lo_(w + 2), hi_(-1) {}

    void add_span(double xa, double xb) {
        xa = std::max(xa, 0.0);
        xb = std::min(xb, static_cast<double>(w_));
        if (!(xb > xa)) return;
        int ia = static_cast<int>(xa), ib = static_cast<int>(xb);
        if (ia == ib) {
            cov_[ia] += xb - xa;
        } else {
            cov_[ia] += ia + 1 - xa;
            cov_[ib] += xb - ib;
            delta_[ia + 1] += 1;
            delta_[ib] -= 1;
        }
        lo_ = std::min(lo_, ia);
        hi_ = std::max(hi_, ib);
    }

    bool empty() const { return hi_ < 0; }

    void flush(Canvas& cv, int row, double r, double g, double b, double opacity) {
        if (hi_ < 0) return;
        double run = 0;
        double* d = cv.pixel(0, row);
        const int last = std::min(hi_, w_ - 1);
        for (int x = lo_; x <= hi_; ++x) {
            run += delta_[x];
            double c = (cov_[x] + run) * (1.0 / kSubScanlines);
            cov_[x] = delta_[x] = 0;
            if (x > last || !(c > 0)) continue;
            double alpha = opacity * std::min(c, 1.0);
            double* p = d + 4 * x;
            double inv = 1 - alpha;
            p[0] = r * alpha + p[0] * inv;
            p[1] = g * alpha + p[1] * inv;
            p[2] = b * alpha + p[2] * inv;
            p[3] = alpha + p[3] * inv;
        }
        cv.mark_dirty(row, row + 1);
        lo_ = w_ + 2;
        hi_ = -1;
    }

private:
    int w_;
    std::vector<double> cov_, delta_;
    int lo_, hi_;
};

}  // namespace

void fill_polygons(Canvas& canvas, const std::vector<Polygon>& polygons, FillRule rule, double r, double g,
                   double b, double opacity) {
    const int W = canvas.width(), H = canvas.height();
    const double kmax = static_cast<double>(kSubScanlines) * H - 1;

    std::vector<Edge> edges;
    for (const Polygon& poly : polygons) {
        const size_t n = poly.size();
        if (n < 3) continue;
        for (size_t i = 0; i < n; ++i) {
            Point a = poly[i], c = poly[(i + 1) % n];
            if (!std::isfinite(a.x) || !std::isfinite(a.y) || !std::isfinite(c.x) || !std::isfinite(c.y)) continue;
            if (a.y == c.y) continue;
            int dir = 1;
            if (a.y > c.y) { std::swap(a, c); dir = -1; }
            double k0 = std::max(std::ceil(a.y * kSubScanlines - 0.5), 0.0);
            double k1 = std::min(std::ceil(c.y * kSubScanlines - 0.5) - 1, kmax);
            if (k0 > k1) continue;
            edges.push_back({a.x, a.y, (c.x - a.x) / (c.y - a.y), static_cast<long>(k0), static_cast<long>(k1), dir});
        }
    }
    if (edges.empty()) return;
    std::sort(edges.begin(), edges.end(), [](const Edge& p, const Edge& q) { return p.k0 < q.k0; });

    RowAccumulator acc(W);
    std::vector<Active> active;
    size_t next = 0;
    long k = edges[0].k0;
    long cur_row = k / kSubScanlines;

    while (next < edges.size() || !active.empty()) {
        if (active.empty() && next < edges.size() && edges[next].k0 > k) k = edges[next].k0;
        long row = k / kSubScanlines;
        if (row != cur_row) {
            acc.flush(canvas, static_cast<int>(cur_row), r, g, b, opacity);
            cur_row = row;
        }
        // Retire finished edges, then admit new ones.
        active.erase(std::remove_if(active.begin(), active.end(), [&](const Active& a) { return a.k1 < k; }),
                     active.end());
        while (next < edges.size() && edges[next].k0 <= k) {
            active.push_back({0, edges[next].dir, edges[next].k1, &edges[next]});
            ++next;
        }
        const double sy = (static_cast<double>(k) + 0.5) / kSubScanlines;
        for (Active& a : active) a.x = a.e->x0 + (sy - a.e->y0) * a.e->slope;
        // Insertion sort: the order changes little between sub-scanlines.
        for (size_t i = 1; i < active.size(); ++i) {
            Active t = active[i];
            size_t j = i;
            while (j > 0 && active[j - 1].x > t.x) { active[j] = active[j - 1]; --j; }
            active[j] = t;
        }
        int wind = 0;
        bool inside = false;
        double start = 0;
        for (const Active& a : active) {
            wind += a.dir;
            bool now = rule == FillRule::NonZero ? wind != 0 : (((wind % 2) + 2) % 2) != 0;
            if (now && !inside) start = a.x;
            else if (!now && inside) acc.add_span(start, a.x);
            inside = now;
        }
        ++k;
    }
    acc.flush(canvas, static_cast<int>(cur_row), r, g, b, opacity);
}

}  // namespace svgraster
