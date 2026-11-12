// Computed painting properties: inheritance, `style` attribute precedence.
#pragma once

#include "svgraster/parse.hpp"
#include "svgraster/raster.hpp"
#include "svgraster/stroke.hpp"
#include "svgraster/xml.hpp"

namespace svgraster {

/// A `fill` or `stroke` value.
struct Paint {
    enum class Kind { None, Color, CurrentColor } kind = Kind::None;
    Rgb color;
};

/// The inherited painting properties of SPEC section 6.
struct Style {
    Paint fill{Paint::Kind::Color, {0, 0, 0}};
    double fill_opacity = 1;
    FillRule fill_rule = FillRule::NonZero;
    Paint stroke{Paint::Kind::None, {0, 0, 0}};
    double stroke_width = 1;
    LineCap line_cap = LineCap::Butt;
    LineJoin line_join = LineJoin::Miter;
    double miter_limit = 4;
    double stroke_opacity = 1;
    Rgb color{0, 0, 0};

    /// The colour a paint resolves to on an element with this style.
    Rgb resolve(const Paint& p) const { return p.kind == Paint::Kind::CurrentColor ? color : p.color; }
};

/// Computes the style of `el` given its parent's computed style.
Style compute_style(const Element& el, const Style& parent);

/// Whether the computed `display` of `el` is exactly `none`.
bool is_display_none(const Element& el);

/// The element's (non-inherited) `opacity`, in [0, 1].
double computed_opacity(const Element& el);

}  // namespace svgraster
