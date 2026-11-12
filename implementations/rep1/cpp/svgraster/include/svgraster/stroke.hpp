// Stroke outlining: turns flattened centrelines into a set of polygons whose
// nonzero-union is the stroked region (SPEC section 8.2).
#pragma once

#include <vector>

#include "svgraster/geometry.hpp"
#include "svgraster/path.hpp"

namespace svgraster {

enum class LineCap { Butt, Round, Square };
enum class LineJoin { Miter, Round, Bevel };

struct StrokeStyle {
    double width = 1;
    LineCap cap = LineCap::Butt;
    LineJoin join = LineJoin::Miter;
    double miter_limit = 4;
};

/// Builds the stroke pieces for `centerline` (polylines in user space), maps
/// them to device space with `ctm` and orients each so its signed area is
/// positive. Round joins and caps are approximated within 0.01 device pixels.
std::vector<Polygon> stroke_polygons(const std::vector<Polyline>& centerline, const StrokeStyle& style,
                                     const Matrix& ctm);

}  // namespace svgraster
