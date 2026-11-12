// Umbrella header for the svgraster library.
//
//   #include <svgraster/svgraster.hpp>
//   std::string ppm = svgraster::render_svg_to_ppm(svg_text, 64, 64);
#pragma once

#include "svgraster/geometry.hpp"
#include "svgraster/parse.hpp"
#include "svgraster/path.hpp"
#include "svgraster/raster.hpp"
#include "svgraster/render.hpp"
#include "svgraster/shapes.hpp"
#include "svgraster/stroke.hpp"
#include "svgraster/style.hpp"
#include "svgraster/xml.hpp"

namespace svgraster {

/// Convenience: renders SVG text to the bytes of a binary PPM (P6) image.
inline std::string render_svg_to_ppm(const std::string& svg_text, int width, int height) {
    return encode_ppm(render_svg(svg_text, width, height));
}

}  // namespace svgraster
