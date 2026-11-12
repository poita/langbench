// Document rendering: viewport, tree walk, `use`, group opacity.
#pragma once

#include <string>

#include "svgraster/raster.hpp"
#include "svgraster/xml.hpp"

namespace svgraster {

/// Renders the SVG document element `root` onto a fresh `width` x `height`
/// canvas (transparent background).
Canvas render_document(const Element& root, int width, int height);

/// Parses `svg_text` and renders it. If the text is not an SVG document the
/// result is a blank canvas.
Canvas render_svg(const std::string& svg_text, int width, int height);

}  // namespace svgraster
