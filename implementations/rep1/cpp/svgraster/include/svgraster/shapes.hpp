// Conversion of SVG shape elements to paths.
#pragma once

#include <optional>

#include "svgraster/path.hpp"
#include "svgraster/xml.hpp"

namespace svgraster {

Path rect_path(double x, double y, double w, double h, double rx, double ry);
Path ellipse_path(double cx, double cy, double rx, double ry);

/// Returns the path of a shape element (`path`, `rect`, `circle`, `ellipse`,
/// `line`, `polyline`, `polygon`), or nullopt when the element is not a shape
/// or draws nothing (e.g. a zero-width rect).
std::optional<Path> shape_to_path(const Element& el);

/// True for the seven shape tags.
bool is_shape_tag(const std::string& tag);

}  // namespace svgraster
