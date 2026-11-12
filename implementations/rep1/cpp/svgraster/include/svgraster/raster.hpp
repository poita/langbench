// RGBA canvas, active-edge scanline polygon filler with 64 sub-scanlines of
// exact horizontal coverage, compositing and PPM encoding.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "svgraster/geometry.hpp"

namespace svgraster {

enum class FillRule { NonZero, EvenOdd };

/// A canvas of premultiplied double-precision RGBA pixels, initially transparent.
/// (Premultiplied is the value the SPEC's source-over recurrences produce.)
class Canvas {
public:
    Canvas(int width, int height);

    int width() const { return w_; }
    int height() const { return h_; }

    /// Pointer to the four channels (r, g, b, a) of pixel (x, y).
    double* pixel(int x, int y) { return &px_[(static_cast<size_t>(y) * w_ + x) * 4]; }
    const double* pixel(int x, int y) const { return &px_[(static_cast<size_t>(y) * w_ + x) * 4]; }

    /// Rows [first, last) that may hold non-transparent pixels.
    int dirty_begin() const { return dirty_lo_; }
    int dirty_end() const { return dirty_hi_; }
    void mark_dirty(int row_begin, int row_end);

    /// Source-over composites `layer` (same size) scaled by `opacity` onto this canvas.
    void composite_layer(const Canvas& layer, double opacity);

    /// Composites over opaque white and returns RGB bytes, rows top to bottom.
    std::vector<uint8_t> to_rgb8() const;

private:
    int w_, h_;
    std::vector<double> px_;
    int dirty_lo_, dirty_hi_;
};

/// Fills the region enclosed by `polygons` (device space, each implicitly
/// closed) with colour (r, g, b in [0,1]) at the given paint opacity,
/// source-over composited using area coverage.
void fill_polygons(Canvas& canvas, const std::vector<Polygon>& polygons, FillRule rule, double r, double g,
                   double b, double opacity);

/// Encodes the canvas as a binary PPM (P6) file image.
std::string encode_ppm(const Canvas& canvas);

}  // namespace svgraster
