#include "svgraster/path.hpp"

#include <algorithm>
#include <cmath>

#include "svgraster/parse.hpp"

namespace svgraster {

// ---------------------------------------------------------------- Path

void Path::move_to(Point p) {
    segs_.push_back({SegType::Move, {p, {}, {}}});
    cur_ = start_ = p;
    open_ = true;
}

void Path::line_to(Point p) {
    if (!open_) move_to(cur_);
    segs_.push_back({SegType::Line, {p, {}, {}}});
    cur_ = p;
}

void Path::cubic_to(Point c1, Point c2, Point p) {
    if (!open_) move_to(cur_);
    segs_.push_back({SegType::Cubic, {c1, c2, p}});
    cur_ = p;
}

void Path::close() {
    if (!open_) return;
    segs_.push_back({SegType::Close, {}});
    cur_ = start_;
    open_ = false;
}

void Path::arc_to(double rx, double ry, double rot_deg, bool large, bool sweep, Point end) {
    const Point p0 = cur_;
    if (p0 == end) return;
    rx = std::fabs(rx);
    ry = std::fabs(ry);
    if (rx == 0 || ry == 0) {
        line_to(end);
        return;
    }
    const double phi = rot_deg * M_PI / 180.0;
    const double cp = std::cos(phi), sp = std::sin(phi);
    const double dx2 = (p0.x - end.x) / 2, dy2 = (p0.y - end.y) / 2;
    const double x1p = cp * dx2 + sp * dy2;
    const double y1p = -sp * dx2 + cp * dy2;
    const double lam = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
    if (lam > 1) {
        double s = std::sqrt(lam);
        rx *= s;
        ry *= s;
    }
    const double rx2 = rx * rx, ry2 = ry * ry;
    double num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
    double den = rx2 * y1p * y1p + ry2 * x1p * x1p;
    double coef = den == 0 ? 0 : std::sqrt(std::max(0.0, num / den));
    if (large == sweep) coef = -coef;
    const double cxp = coef * rx * y1p / ry;
    const double cyp = -coef * ry * x1p / rx;
    const double cx = cp * cxp - sp * cyp + (p0.x + end.x) / 2;
    const double cy = sp * cxp + cp * cyp + (p0.y + end.y) / 2;
    const double ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry;
    const double vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry;
    const double theta1 = std::atan2(uy, ux);
    double dtheta = std::atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    if (sweep && dtheta < 0) dtheta += 2 * M_PI;
    else if (!sweep && dtheta > 0) dtheta -= 2 * M_PI;

    int n = std::max(1, static_cast<int>(std::ceil(std::fabs(dtheta) / (M_PI / 4))));
    const double delta = dtheta / n;
    const double k = 4.0 / 3.0 * std::tan(delta / 4);
    auto E = [&](double t) {
        double x = rx * std::cos(t), y = ry * std::sin(t);
        return Point{cx + cp * x - sp * y, cy + sp * x + cp * y};
    };
    auto dE = [&](double t) {
        double x = -rx * std::sin(t), y = ry * std::cos(t);
        return Point{cp * x - sp * y, sp * x + cp * y};
    };
    for (int i = 0; i < n; ++i) {
        double t0 = theta1 + i * delta, t1 = t0 + delta;
        // The last segment ends at the exact endpoint (the first starts at the current point).
        Point s1 = i == n - 1 ? end : E(t1);
        cubic_to(E(t0) + dE(t0) * k, E(t1) - dE(t1) * k, s1);
    }
}

// ---------------------------------------------------------------- path data

namespace {

bool starts_number(char c) { return (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'; }

bool is_command(char c) {
    switch (c) {
        case 'M': case 'm': case 'L': case 'l': case 'H': case 'h': case 'V': case 'v':
        case 'C': case 'c': case 'S': case 's': case 'Q': case 'q': case 'T': case 't':
        case 'A': case 'a': case 'Z': case 'z':
            return true;
        default:
            return false;
    }
}

}  // namespace

Path parse_path_data(const std::string& d) {
    Path path;
    Scanner sc(d);
    char cmd = 0;
    // Control point left by the previous command, for S/T reflection.
    enum class Prev { Other, Cubic, Quad } prev = Prev::Other;
    Point prev_ctrl;
    bool first = true;

    auto num = [&](double& out) {
        sc.skip_space_and_commas();
        auto v = sc.number();
        if (!v) return false;
        out = *v;
        return true;
    };
    auto flag = [&](bool& out) {
        sc.skip_space_and_commas();
        char c = sc.peek();
        if (c != '0' && c != '1') return false;
        sc.advance();
        out = c == '1';
        return true;
    };

    for (;;) {
        sc.skip_space_and_commas();
        if (sc.at_end()) break;
        char c = sc.peek();
        if (is_command(c)) {
            if (first && c != 'M' && c != 'm') break;
            sc.advance();
            cmd = c;
            first = false;
            if (cmd == 'Z' || cmd == 'z') {
                path.close();
                prev = Prev::Other;
                continue;
            }
        } else if (starts_number(c)) {
            if (cmd == 0 || cmd == 'Z' || cmd == 'z') break;
        } else {
            break;
        }

        const bool rel = cmd >= 'a';
        const Point cur = path.current();
        const double ox = rel ? cur.x : 0, oy = rel ? cur.y : 0;
        double v[7];
        bool ok = true;
        Prev next_prev = Prev::Other;
        Point next_ctrl;

        switch (cmd) {
            case 'M': case 'm':
                ok = num(v[0]) && num(v[1]);
                if (ok) {
                    path.move_to({ox + v[0], oy + v[1]});
                    cmd = rel ? 'l' : 'L';  // implicit repeats are line-tos
                }
                break;
            case 'L': case 'l':
                ok = num(v[0]) && num(v[1]);
                if (ok) path.line_to({ox + v[0], oy + v[1]});
                break;
            case 'H': case 'h':
                ok = num(v[0]);
                if (ok) path.line_to({ox + v[0], cur.y});
                break;
            case 'V': case 'v':
                ok = num(v[0]);
                if (ok) path.line_to({cur.x, oy + v[0]});
                break;
            case 'C': case 'c':
                ok = num(v[0]) && num(v[1]) && num(v[2]) && num(v[3]) && num(v[4]) && num(v[5]);
                if (ok) {
                    Point c2{ox + v[2], oy + v[3]};
                    path.cubic_to({ox + v[0], oy + v[1]}, c2, {ox + v[4], oy + v[5]});
                    next_prev = Prev::Cubic;
                    next_ctrl = c2;
                }
                break;
            case 'S': case 's':
                ok = num(v[0]) && num(v[1]) && num(v[2]) && num(v[3]);
                if (ok) {
                    Point c1 = prev == Prev::Cubic ? cur * 2 - prev_ctrl : cur;
                    Point c2{ox + v[0], oy + v[1]};
                    path.cubic_to(c1, c2, {ox + v[2], oy + v[3]});
                    next_prev = Prev::Cubic;
                    next_ctrl = c2;
                }
                break;
            case 'Q': case 'q':
                ok = num(v[0]) && num(v[1]) && num(v[2]) && num(v[3]);
                if (ok) {
                    Point q{ox + v[0], oy + v[1]}, e{ox + v[2], oy + v[3]};
                    path.cubic_to(cur + (q - cur) * (2.0 / 3.0), e + (q - e) * (2.0 / 3.0), e);
                    next_prev = Prev::Quad;
                    next_ctrl = q;
                }
                break;
            case 'T': case 't':
                ok = num(v[0]) && num(v[1]);
                if (ok) {
                    Point q = prev == Prev::Quad ? cur * 2 - prev_ctrl : cur;
                    Point e{ox + v[0], oy + v[1]};
                    path.cubic_to(cur + (q - cur) * (2.0 / 3.0), e + (q - e) * (2.0 / 3.0), e);
                    next_prev = Prev::Quad;
                    next_ctrl = q;
                }
                break;
            case 'A': case 'a': {
                bool large = false, sweep = false;
                ok = num(v[0]) && num(v[1]) && num(v[2]) && flag(large) && flag(sweep) && num(v[3]) && num(v[4]);
                if (ok) path.arc_to(v[0], v[1], v[2], large, sweep, {ox + v[3], oy + v[4]});
                break;
            }
            default:
                ok = false;
        }
        if (!ok) break;
        prev = next_prev;
        prev_ctrl = next_ctrl;
    }
    return path;
}

// ---------------------------------------------------------------- flattening

namespace {

int step_count(const Point& p0, const Point& p1, const Point& p2, const Point& p3) {
    Point a = p0 - p1 * 2 + p2;
    Point b = p1 - p2 * 2 + p3;
    double m = std::max(dot(a, a), dot(b, b));
    if (!(m > 0)) return 1;
    double n = std::ceil(std::sqrt(0.75 * std::sqrt(m) / 0.01));
    if (!(n >= 1)) return 1;
    return static_cast<int>(std::min(n, 1000.0));
}

}  // namespace

std::vector<Polyline> flatten(const Path& path, const Matrix& to_device, bool output_device) {
    std::vector<Polyline> out;
    Polyline cur;
    bool have = false;      // cur holds a subpath
    bool has_draw = false;  // ... with at least one drawing segment
    auto emit = [&](Point p) { cur.pts.push_back(output_device ? to_device.apply(p) : p); };
    auto finish = [&]() {
        if (have && has_draw) out.push_back(std::move(cur));
        cur = Polyline();
        have = has_draw = false;
    };
    Point last;
    for (const Segment& s : path.segments()) {
        switch (s.type) {
            case SegType::Move:
                finish();
                have = true;
                emit(s.p[0]);
                last = s.p[0];
                break;
            case SegType::Line:
                if (!have) break;
                emit(s.p[0]);
                has_draw = true;
                last = s.p[0];
                break;
            case SegType::Cubic: {
                if (!have) break;
                Point d0 = to_device.apply(last), d1 = to_device.apply(s.p[0]);
                Point d2 = to_device.apply(s.p[1]), d3 = to_device.apply(s.p[2]);
                int n = step_count(d0, d1, d2, d3);
                for (int i = 1; i < n; ++i) {
                    double t = static_cast<double>(i) / n, u = 1 - t;
                    double b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t;
                    emit({b0 * last.x + b1 * s.p[0].x + b2 * s.p[1].x + b3 * s.p[2].x,
                          b0 * last.y + b1 * s.p[0].y + b2 * s.p[1].y + b3 * s.p[2].y});
                }
                emit(s.p[2]);
                has_draw = true;
                last = s.p[2];
                break;
            }
            case SegType::Close:
                if (have) {
                    cur.closed = true;
                    has_draw = true;
                    finish();
                }
                break;
        }
    }
    finish();
    return out;
}

}  // namespace svgraster
