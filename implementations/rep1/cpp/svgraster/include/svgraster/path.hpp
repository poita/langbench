// Paths made of move / line / cubic / close segments, path-data parsing,
// elliptical arc conversion and curve flattening.
#pragma once

#include <string>
#include <vector>

#include "svgraster/geometry.hpp"

namespace svgraster {

enum class SegType { Move, Line, Cubic, Close };

struct Segment {
    SegType type;
    Point p[3];  // Move/Line: p[0]; Cubic: control 1, control 2, end
};

/// A path in some coordinate system. After a Close, a drawing segment is
/// always preceded by an explicit Move to the closed subpath's start.
class Path {
public:
    void move_to(Point p);
    void line_to(Point p);
    void cubic_to(Point c1, Point c2, Point p);
    void close();

    /// Appends the SVG elliptical arc from the current point to `end`
    /// (SVG 1.1 implementation notes F.6.5-F.6.6), as cubic segments.
    void arc_to(double rx, double ry, double x_axis_rotation_deg, bool large_arc, bool sweep, Point end);

    const std::vector<Segment>& segments() const { return segs_; }
    bool empty() const { return segs_.empty(); }
    Point current() const { return cur_; }

private:
    std::vector<Segment> segs_;
    Point cur_, start_;
    bool open_ = false;  // a subpath is open (Move seen, not closed)
};

/// Parses SVG path data. Parsing stops at the first unexpected token and the
/// commands read so far are kept.
Path parse_path_data(const std::string& d);

/// A flattened subpath.
struct Polyline {
    Polygon pts;
    bool closed = false;
};

/// Flattens `path` to polylines. The step count of every curve is chosen so
/// the result is within 0.01 device pixels when the path is mapped to device
/// space by `to_device`. If `output_device` is true the returned points are in
/// device space, otherwise they stay in the path's own coordinates.
/// A subpath consisting of a lone Move is omitted.
std::vector<Polyline> flatten(const Path& path, const Matrix& to_device, bool output_device);

}  // namespace svgraster
